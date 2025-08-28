#!/bin/bash
# Quick Health Check Script - Ubuntu
# Localização: /home/ubuntu/scripts/quick-health.sh

set -euo pipefail

# Configurações
ANSIBLE_DIR="/opt/ansible-deploys"
SERVERS=(172.17.3.205 172.17.3.21)
HEALTH_URL="/totvs-menu"
TOMCAT_PORT=8080

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Contadores globais
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARNINGS=0
FAILURES=0

# Funções de log
log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    ((WARNINGS++))
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ((FAILURES++))
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Registrar resultado de check
check_result() {
    local result=$1
    local message=$2
    local show_emoji=${3:-true}
    
    ((TOTAL_CHECKS++))
    
    if [ "$result" -eq 0 ]; then
        ((PASSED_CHECKS++))
        if [ "$show_emoji" = "true" ]; then
            echo -e "  ✅ $message"
        else
            echo -e "  ${GREEN}OK${NC} - $message"
        fi
    else
        ((FAILURES++))
        if [ "$show_emoji" = "true" ]; then
            echo -e "  ❌ $message"
        else
            echo -e "  ${RED}FAIL${NC} - $message"
        fi
    fi
}

# Header bonito
show_header() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    🏥 QUICK HEALTH CHECK 🏥                      ║${NC}"
    echo -e "${BLUE}║                   Ubuntu Tomcat Environment                     ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Timestamp: $(date '+%Y-%m-%d %H:%M:%S')                                  ║${NC}"
    echo -e "${BLUE}║  Servidores: 7 frontend                                          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

# 1. Check básico de conectividade
check_basic_connectivity() {
    echo -e "${PURPLE}🔌 1. CONECTIVIDADE BÁSICA${NC}"
    
    if [ ! -d "$ANSIBLE_DIR" ]; then
        check_result 1 "Diretório Ansible: $ANSIBLE_DIR"
        return
    fi
    
    cd "$ANSIBLE_DIR"
    
    # Ping Ansible
    local ansible_ok=0
    if ansible -i inventory.yml frontend_servers -m ping --one-line >/dev/null 2>&1; then
        ansible_ok=1
    fi
    check_result $((1 - ansible_ok)) "Ansible ping: $ansible_ok/7 servidores"
    
    # SSH direto (mais rápido)
    local ssh_ok=0
    for server in "${SERVERS[@]}"; do
        if timeout 3 ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no ubuntu@$server "echo ok" >/dev/null 2>&1; then
            ((ssh_ok++))
        fi
    done
    check_result $((7 - ssh_ok)) "SSH direto: $ssh_ok/7 servidores"
    
    echo
}

# 2. Check serviços Tomcat
check_tomcat_services() {
    echo -e "${PURPLE}🚀 2. SERVIÇOS TOMCAT${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Status dos serviços
    local active_count=$(ansible -i inventory.yml frontend_servers -m shell -a "systemctl is-active tomcat" 2>/dev/null | grep -c "active" || echo 0)
    check_result $((7 - active_count)) "Tomcat ativo: $active_count/7"
    
    # Enabled para boot
    local enabled_count=$(ansible -i inventory.yml frontend_servers -m shell -a "systemctl is-enabled tomcat" 2>/dev/null | grep -c "enabled" || echo 0)  
    check_result $((7 - enabled_count)) "Auto-start configurado: $enabled_count/7"
    
    # Processos Java
    local java_count=$(ansible -i inventory.yml frontend_servers -m shell -a "pgrep -c java" 2>/dev/null | grep -E '^[0-9]+$' | wc -l)
    check_result $((7 - java_count)) "Processos Java: $java_count/7"
    
    echo
}

# 3. Health check das aplicações
check_application_health() {
    echo -e "${PURPLE}🌐 3. APLICAÇÕES WEB${NC}"
    
    local healthy=0
    local response_times=()
    local failed_servers=()
    
    for server in "${SERVERS[@]}"; do
        # Health check HTTP
        local response=$(timeout 10 curl -k -s -o /dev/null -w "%{http_code}:%{time_total}" \
            "https://$server:$TOMCAT_PORT$HEALTH_URL" 2>/dev/null || echo "000:999")
        
        local http_code=$(echo $response | cut -d: -f1)
        local time_total=$(echo $response | cut -d: -f2)
        
        case $http_code in
            200|301|302)
                ((healthy++))
                response_times+=("$time_total")
                ;;
            *)
                failed_servers+=("$server ($http_code)")
                ;;
        esac
    done
    
    check_result $((7 - healthy)) "Aplicações saudáveis: $healthy/7"
    
    # Tempo médio de resposta
    if [ ${#response_times[@]} -gt 0 ]; then
        local avg_time=$(printf "%.2f" $(echo "${response_times[*]}" | awk '{for(i=1;i<=NF;i++) sum+=$i; print sum/NF}'))
        if (( $(echo "$avg_time > 2.0" | bc -l) )); then
            warn "Tempo de resposta alto: ${avg_time}s"
        else
            info "Tempo médio de resposta: ${avg_time}s"
        fi
    fi
    
    # Mostrar servidores com problema
    if [ ${#failed_servers[@]} -gt 0 ]; then
        info "Servidores com problemas:"
        for server_info in "${failed_servers[@]}"; do
            echo -e "    ${RED}•${NC} $server_info"
        done
    fi
    
    echo
}

# 4. Check de recursos do sistema  
check_system_resources() {
    echo -e "${PURPLE}📊 4. RECURSOS DO SISTEMA${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # CPU Load
    local high_cpu=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "uptime | awk -F'load average:' '{print \$2}' | awk -F, '{if(\$1+0>2.0) print \"HIGH\"; else print \"OK\"}'" \
        2>/dev/null | grep -c "HIGH" || echo 0)
    check_result $high_cpu "CPU Load aceitável: $((7 - high_cpu))/7"
    
    # Memória
    local high_mem=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "free | grep Mem | awk '{if((\$3/\$2)*100>85) print \"HIGH\"; else print \"OK\"}'" \
        2>/dev/null | grep -c "HIGH" || echo 0)
    check_result $high_mem "Uso de memória OK: $((7 - high_mem))/7"
    
    # Disco
    local low_disk=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "df /opt/tomcat | tail -1 | awk '{if(\$5+0>90) print \"LOW\"; else print \"OK\"}'" \
        2>/dev/null | grep -c "LOW" || echo 0)
    check_result $low_disk "Espaço em disco OK: $((7 - low_disk))/7"
    
    echo
}

# 5. Check de erros nos logs
check_error_logs() {
    echo -e "${PURPLE}📋 5. LOGS DE ERRO${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Erros críticos
    local critical_errors=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "tail -50 /opt/tomcat/current/logs/catalina.out | grep -c 'SEVERE\|OutOfMemory\|Exception.*Error' || echo 0" \
        2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    
    if [ "$critical_errors" -eq 0 ]; then
        check_result 0 "Nenhum erro crítico recente"
    else
        check_result 1 "$critical_errors erros críticos encontrados"
    fi
    
    # Warnings excessivos (mais de 10 por servidor)
    local warning_servers=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "tail -50 /opt/tomcat/current/logs/catalina.out | grep -c 'WARN' || echo 0" \
        2>/dev/null | awk '$1>10 {count++} END {print count+0}')
    
    if [ "$warning_servers" -eq 0 ]; then
        check_result 0 "Nível de warnings aceitável"
    else
        check_result 1 "$warning_servers servidores com warnings excessivos"
    fi
    
    echo
}

# 6. Check custom directories (se existirem)
check_custom_directories() {
    echo -e "${PURPLE}🔒 6. DIRETÓRIOS CUSTOM${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Check custom
    local custom_exists=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "[ -d /opt/tomcat/current/webapps/custom ] && echo 1 || echo 0" \
        2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    
    # Check custom_fsw  
    local custom_fsw_exists=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "[ -d /opt/tomcat/current/webapps/custom_fsw ] && echo 1 || echo 0" \
        2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    
    if [ "$custom_exists" -gt 0 ]; then
        info "Diretório 'custom': $custom_exists/7 servidores"
        
        # Verificar permissões se existe
        local custom_perms=$(ansible -i inventory.yml frontend_servers -m shell \
            -a "[ -d /opt/tomcat/current/webapps/custom ] && [ \$(stat -c '%U' /opt/tomcat/current/webapps/custom) = 'tomcat' ] && echo 1 || echo 0" \
            2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        check_result $((custom_exists - custom_perms)) "Permissões 'custom' corretas: $custom_perms/$custom_exists"
    else
        info "Diretório 'custom': não encontrado (normal se não usado)"
    fi
    
    if [ "$custom_fsw_exists" -gt 0 ]; then
        info "Diretório 'custom_fsw': $custom_fsw_exists/7 servidores"
        
        local custom_fsw_perms=$(ansible -i inventory.yml frontend_servers -m shell \
            -a "[ -d /opt/tomcat/current/webapps/custom_fsw ] && [ \$(stat -c '%U' /opt/tomcat/current/webapps/custom_fsw) = 'tomcat' ] && echo 1 || echo 0" \
            2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        check_result $((custom_fsw_exists - custom_fsw_perms)) "Permissões 'custom_fsw' corretas: $custom_fsw_perms/$custom_fsw_exists"
    else
        info "Diretório 'custom_fsw': não encontrado (normal se não usado)"
    fi
    
    echo
}

# Relatório final
generate_final_report() {
    local success_rate=0
    if [ "$TOTAL_CHECKS" -gt 0 ]; then
        success_rate=$(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))
    fi
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                         📊 RELATÓRIO FINAL                       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${CYAN}📈 Estatísticas:${NC}"
    echo "   • Total de verificações: $TOTAL_CHECKS"
    echo "   • Verificações OK: $PASSED_CHECKS"
    echo "   • Warnings: $WARNINGS"
    echo "   • Falhas: $FAILURES"
    echo "   • Taxa de sucesso: $success_rate%"
    echo
    
    # Status final
    if [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        echo -e "${GREEN}🎉 SISTEMA 100% SAUDÁVEL!${NC}"
        echo -e "${GREEN}   Todos os checks passaram. Ambiente operacional.${NC}"
        return 0
    elif [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  SISTEMA OPERACIONAL COM ALERTAS${NC}"
        echo -e "${YELLOW}   $WARNINGS warning(s) detectado(s). Sistema funcionando.${NC}"
        return 1
    elif [ "$success_rate" -ge 70 ]; then
        echo -e "${YELLOW}🔧 SISTEMA OPERACIONAL COM PROBLEMAS${NC}"
        echo -e "${YELLOW}   $FAILURES falha(s) detectada(s). Monitoramento recomendado.${NC}"
        return 2
    else
        echo -e "${RED}🚨 SISTEMA COM PROBLEMAS CRÍTICOS${NC}"
        echo -e "${RED}   $FAILURES falha(s) crítica(s). Ação imediata necessária!${NC}"
        return 3
    fi
}

# Health check rápido (apenas essencial)
quick_check() {
    show_header
    log "⚡ Executando health check rápido..."
    echo
    
    # Reset contadores
    TOTAL_CHECKS=0
    PASSED_CHECKS=0
    WARNINGS=0
    FAILURES=0
    
    # Apenas checks essenciais
    check_basic_connectivity
    check_tomcat_services
    check_application_health
    
    generate_final_report
}

# Health check completo
full_check() {
    show_header
    log "🔍 Executando health check completo..."
    echo
    
    # Reset contadores
    TOTAL_CHECKS=0
    PASSED_CHECKS=0
    WARNINGS=0
    FAILURES=0
    
    # Todos os checks
    check_basic_connectivity
    check_tomcat_services
    check_application_health
    check_system_resources
    check_error_logs
    check_custom_directories
    
    generate_final_report
}

# Mostrar apenas aplicações
check_apps_only() {
    show_header
    log "🌐 Verificando apenas aplicações..."
    echo
    
    check_application_health
    
    if [ "$FAILURES" -eq 0 ]; then
        success "Todas as aplicações estão respondendo!"
    else
        error "$FAILURES aplicações com problemas"
    fi
}

# Mostrar ajuda
show_help() {
    echo -e "${BLUE}Quick Health Check - Ubuntu Environment${NC}"
    echo
    echo "Verificação rápida da saúde do cluster Tomcat."
    echo
    echo "Uso:"
    echo "  $0                    # Health check rápido (recomendado)"
    echo "  $0 --full            # Health check completo"
    echo "  $0 --apps            # Apenas aplicações"
    echo "  $0 --quick           # Apenas conectividade e serviços"
    echo "  $0 --help           # Esta ajuda"
    echo
    echo "Códigos de saída:"
    echo "  0 = Sistema 100% saudável"
    echo "  1 = Operacional com warnings"
    echo "  2 = Operacional com alguns problemas"
    echo "  3 = Problemas críticos"
    echo
    echo -e "${CYAN}💡 Dicas de uso:${NC}"
    echo "  • Execute após cada deploy WAR"
    echo "  • Use '--full' para diagnóstico detalhado"
    echo "  • Combine com 'watch quick-health.sh' para monitoramento"
}

# Função principal
main() {
    case "${1:-}" in
        --full|-f)
            full_check
            ;;
        --apps|-a)
            check_apps_only
            ;;
        --quick|-q)
            # Reset contadores
            TOTAL_CHECKS=0
            PASSED_CHECKS=0
            WARNINGS=0
            FAILURES=0
            
            show_header
            log "⚡ Health check super rápido..."
            echo
            check_basic_connectivity
            check_tomcat_services
            generate_final_report
            ;;
        --help|-h)
            show_help
            ;;
        "")
            quick_check  # Default: check rápido
            ;;
        *)
            error "Opção inválida: $1"
            show_help
            exit 1
            ;;
    esac
}

# Trap para limpeza
cleanup() {
    echo
    log "Health check interrompido pelo usuário"
    exit 130
}

trap cleanup SIGINT SIGTERM

# Executar
main "$@"