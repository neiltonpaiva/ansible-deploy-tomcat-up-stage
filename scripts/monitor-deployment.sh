#!/bin/bash
# Monitor deployment in real-time - Ubuntu Environment

set -euo pipefail

# Configurações Ubuntu
TOMCAT_LOG="/opt/tomcat/current/logs/catalina.out"
DEPLOY_LOG="/opt/ansible-deploys/logs/current-deploy.log"
SERVERS=(172.17.3.204 172.17.3.21)

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Função de log
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verificar se é Ubuntu
check_ubuntu() {
    if [ ! -f /etc/lsb-release ] || ! grep -q "Ubuntu" /etc/lsb-release; then
        warn "Este script foi otimizado para Ubuntu"
        warn "OS detectado: $(lsb_release -d 2>/dev/null || echo 'Desconhecido')"
    fi
}

# Monitor logs durante deploy em um servidor específico
monitor_deploy_server() {
    local server=$1
    local server_name="tomcat-$(printf "%02d" $(($(echo $server | cut -d'.' -f4) % 100)))"
    
    log "Monitorando deploy em $server ($server_name)..."
    
    # Criar arquivo de log local
    local local_log="/tmp/monitor_${server_name}_$(date +%Y%m%d_%H%M%S).log"
    
    # Monitorar via SSH
    {
        echo "=== Monitoramento iniciado: $server ($server_name) ===" 
        echo "Timestamp: $(date)"
        echo ""
        
        # Conectar via SSH e monitorar logs do Tomcat
        timeout 300 ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$server "
            echo 'Conectado em $server - Monitorando logs...'
            
            # Verificar se o arquivo de log existe
            if [ ! -f '$TOMCAT_LOG' ]; then
                echo 'ERRO: Arquivo de log do Tomcat não encontrado: $TOMCAT_LOG'
                exit 1
            fi
            
            # Monitorar logs com filtros específicos
            tail -f $TOMCAT_LOG | grep --line-buffered -E 'Deployment|ERROR|SEVERE|startup|Exception|WARN|INFO.*Starting|INFO.*Stopping'
        " 2>&1
        
    } | tee "$local_log" | while read line; do
        # Adicionar timestamp e servidor a cada linha
        echo -e "${BLUE}[$server_name]${NC} $(date '+%H:%M:%S') - $line"
        
        # Detectar eventos importantes
        case "$line" in
            *"Deployment of web application"*)
                echo -e "${GREEN}✓ [$server_name] Deploy detectado${NC}"
                ;;
            *"ERROR"*|*"SEVERE"*|*"Exception"*)
                echo -e "${RED}⚠ [$server_name] Erro detectado${NC}"
                ;;
            *"Server startup in"*)
                echo -e "${GREEN}🚀 [$server_name] Startup completo${NC}"
                ;;
        esac
    done
    
    log "Monitoramento finalizado para $server - Log salvo: $local_log"
}

# Monitor logs de todos os servidores em paralelo
monitor_all_servers() {
    log "Iniciando monitoramento de todos os servidores Ubuntu..."
    
    local pids=()
    
    # Iniciar monitoramento em background para cada servidor
    for server in "${SERVERS[@]}"; do
        monitor_deploy_server "$server" &
        pids+=($!)
        sleep 2  # Pequeno delay entre conexões
    done
    
    log "Monitoramento iniciado para ${#SERVERS[@]} servidores"
    log "PIDs: ${pids[*]}"
    log "Pressione Ctrl+C para parar o monitoramento"
    
    # Aguardar todos os processos ou timeout de 5 minutos
    local timeout=300
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local running=0
        for pid in "${pids[@]}"; do
            if kill -0 $pid 2>/dev/null; then
                ((running++))
            fi
        done
        
        if [ $running -eq 0 ]; then
            log "Todos os monitoramentos finalizaram"
            break
        fi
        
        sleep 5
        ((elapsed+=5))
    done
    
    # Matar processos restantes se ainda estiverem rodando
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null
        fi
    done
    
    log "Monitoramento concluído"
}

# Monitor de um servidor específico
monitor_single_server() {
    local server=$1
    
    if [[ ! " ${SERVERS[@]} " =~ " $server " ]]; then
        error "Servidor não encontrado na lista: $server"
        echo "Servidores disponíveis:"
        for s in "${SERVERS[@]}"; do
            echo "  - $s"
        done
        exit 1
    fi
    
    monitor_deploy_server "$server"
}

# Verificar conectividade dos servidores
check_connectivity() {
    log "Verificando conectividade SSH com servidores Ubuntu..."
    
    local reachable=()
    local unreachable=()
    
    for server in "${SERVERS[@]}"; do
        echo -n "Testando $server... "
        if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ubuntu@$server "echo 'OK'" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
            reachable+=("$server")
        else
            echo -e "${RED}✗${NC}"
            unreachable+=("$server")
        fi
    done
    
    echo ""
    log "Servidores acessíveis: ${#reachable[@]}/${#SERVERS[@]}"
    
    if [ ${#unreachable[@]} -gt 0 ]; then
        warn "Servidores inacessíveis:"
        for server in "${unreachable[@]}"; do
            echo "  - $server"
        done
    fi
    
    return ${#unreachable[@]}
}

# Status dos serviços Tomcat
check_tomcat_status() {
    log "Verificando status do Tomcat nos servidores Ubuntu..."
    
    for server in "${SERVERS[@]}"; do
        echo -e "${BLUE}=== $server ===${NC}"
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@$server "
            echo 'OS: \$(lsb_release -d | cut -f2)'
            echo 'Tomcat Status: \$(systemctl is-active tomcat)'
            echo 'Uptime: \$(uptime -p)'
            echo 'Load: \$(uptime | awk -F\"load average:\" \"{print \\\$2}\")'
            echo 'Memory: \$(free -h | grep Mem | awk \"{print \\\$3\"/\"\\\$2}\")'
            echo 'Disk: \$(df -h /opt/tomcat | tail -1 | awk \"{print \\\$5}\")'
            echo 'Java Processes: \$(pgrep -c java || echo 0)'
        " 2>/dev/null || echo -e "${RED}Conexão falhou${NC}"
        echo ""
    done
}

# Mostrar ajuda
show_help() {
    echo "Monitor de Deploy - Ubuntu Environment"
    echo ""
    echo "Uso:"
    echo "  $0                    # Monitorar todos os servidores"
    echo "  $0 -s <IP>           # Monitorar servidor específico"
    echo "  $0 --connectivity    # Verificar conectividade"
    echo "  $0 --status         # Status dos serviços"
    echo "  $0 --help           # Esta ajuda"
    echo ""
    echo "Servidores configurados:"
    for i in "${!SERVERS[@]}"; do
        echo "  tomcat-$(printf "%02d" $((i+1))): ${SERVERS[$i]}"
    done
    echo ""
    echo "Exemplos:"
    echo "  $0 -s 172.17.3.21           # Monitor servidor específico"
    echo "  $0 --connectivity           # Testar SSH"
    echo "  $0 --status                 # Ver status Tomcat"
}

# Função principal
main() {
    check_ubuntu
    
    case "${1:-}" in
        -s|--server)
            if [ -z "${2:-}" ]; then
                error "Especifique o IP do servidor"
                exit 1
            fi
            monitor_single_server "$2"
            ;;
        --connectivity)
            check_connectivity
            ;;
        --status)
            check_tomcat_status
            ;;
        --help|-h)
            show_help
            ;;
        "")
            monitor_all_servers
            ;;
        *)
            error "Opção inválida: $1"
            show_help
            exit 1
            ;;
    esac
}

# Trap para limpeza ao sair
cleanup() {
    log "Interrompido pelo usuário - fazendo limpeza..."
    # Matar processos filhos
    jobs -p | xargs -r kill 2>/dev/null
    exit 0
}

trap cleanup SIGINT SIGTERM

# Executar função principal
main "$@"