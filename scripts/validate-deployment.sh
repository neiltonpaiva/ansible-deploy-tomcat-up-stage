#!/bin/bash
# Validate deployment across all servers - Ubuntu Environment

set -euo pipefail

# Configurações Ubuntu
SERVERS=(172.17.3.204 172.17.3.21)
ANSIBLE_DIR="/opt/ansible-deploys"
TOMCAT_PORT=8080
HEALTH_URL="/totvs-menu"

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Contadores
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

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

info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Verificar se é Ubuntu
check_ubuntu() {
    if [ ! -f /etc/lsb-release ] || ! grep -q "Ubuntu" /etc/lsb-release; then
        warn "Este script foi otimizado para Ubuntu"
        warn "OS detectado: $(lsb_release -d 2>/dev/null || echo 'Desconhecido')"
    fi
}

# Incrementar contadores de teste
test_result() {
    local result=$1
    local message=$2
    
    ((TOTAL_TESTS++))
    
    if [ "$result" -eq 0 ]; then
        ((PASSED_TESTS++))
        echo -e "  ✅ $message"
    else
        ((FAILED_TESTS++))
        echo -e "  ❌ $message"
    fi
}

# Validação completa do deployment
validate_deployment() {
    log "🔍 Iniciando validação completa do deployment Ubuntu..."
    echo
    
    # Reset dos contadores
    TOTAL_TESTS=0
    PASSED_TESTS=0
    FAILED_TESTS=0
    
    # 1. Teste de conectividade Ansible
    validate_ansible_connectivity
    
    # 2. Verificar status dos serviços
    validate_service_status
    
    # 3. Testar conectividade de rede
    validate_network_connectivity
    
    # 4. Health check das aplicações
    validate_application_health
    
    # 5. Verificar logs de erro
    validate_error_logs
    
    # 6. Verificar integridade dos custom directories
    validate_custom_directories
    
    # 7. Teste de performance básico
    validate_basic_performance
    
    # Relatório final
    generate_final_report
}

# 1. Validar conectividade Ansible
validate_ansible_connectivity() {
    echo -e "${BLUE}=== 1. Teste de Conectividade Ansible ===${NC}"
    
    if [ ! -d "$ANSIBLE_DIR" ]; then
        test_result 1 "Diretório Ansible não encontrado: $ANSIBLE_DIR"
        return
    fi
    
    cd "$ANSIBLE_DIR"
    
    # Teste ping do Ansible
    if ansible -i inventory.yml frontend_servers -m ping --one-line >/dev/null 2>&1; then
        test_result 0 "Conectividade Ansible: OK"
        
        # Contar servidores acessíveis
        local accessible=$(ansible -i inventory.yml frontend_servers -m ping --one-line 2>/dev/null | grep -c "SUCCESS" || echo 0)
        test_result 0 "Servidores acessíveis via Ansible: $accessible/${#SERVERS[@]}"
    else
        test_result 1 "Conectividade Ansible: FALHOU"
    fi
    
    echo
}

# 2. Validar status dos serviços
validate_service_status() {
    echo -e "${BLUE}=== 2. Status dos Serviços Tomcat ===${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Verificar status do serviço
    local active_services=$(ansible -i inventory.yml frontend_servers -m shell -a "systemctl is-active tomcat" 2>/dev/null | grep -c "active" || echo 0)
    
    if [ "$active_services" -eq ${#SERVERS[@]} ]; then
        test_result 0 "Todos os serviços Tomcat ativos: $active_services/${#SERVERS[@]}"
    else
        test_result 1 "Serviços Tomcat inativos detectados: $active_services/${#SERVERS[@]} ativos"
    fi
    
    # Verificar se estão enabled
    local enabled_services=$(ansible -i inventory.yml frontend_servers -m shell -a "systemctl is-enabled tomcat" 2>/dev/null | grep -c "enabled" || echo 0)
    
    if [ "$enabled_services" -eq ${#SERVERS[@]} ]; then
        test_result 0 "Todos os serviços configurados para inicialização automática"
    else
        test_result 1 "Alguns serviços não estão configurados para auto-start: $enabled_services/${#SERVERS[@]}"
    fi
    
    echo
}

# 3. Validar conectividade de rede
validate_network_connectivity() {
    echo -e "${BLUE}=== 3. Conectividade de Rede ===${NC}"
    
    local reachable=0
    local port_open=0
    
    for server in "${SERVERS[@]}"; do
        # Teste de ping/SSH
        if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ubuntu@$server "echo 'OK'" >/dev/null 2>&1; then
            ((reachable++))
        fi
        
        # Teste de porta Tomcat
        if timeout 3 bash -c "</dev/tcp/$server/$TOMCAT_PORT" >/dev/null 2>&1; then
            ((port_open++))
        fi
    done
    
    test_result $((${#SERVERS[@]} - reachable)) "SSH acessível: $reachable/${#SERVERS[@]}"
    test_result $((${#SERVERS[@]} - port_open)) "Porta Tomcat ($TOMCAT_PORT) aberta: $port_open/${#SERVERS[@]}"
    
    echo
}

# 4. Validar saúde das aplicações
validate_application_health() {
    echo -e "${BLUE}=== 4. Health Check das Aplicações ===${NC}"
    
    local healthy_apps=0
    local response_times=()
    
    for server in "${SERVERS[@]}"; do
        echo -n "  Testando $server... "
        
        # Teste HTTP com curl
        local response=$(curl -k -s -o /dev/null -w "%{http_code}:%{time_total}" \
            "https://$server:$TOMCAT_PORT$HEALTH_URL" 2>/dev/null || echo "000:0.000")
        
        local http_code=$(echo $response | cut -d: -f1)
        local time_total=$(echo $response | cut -d: -f2)
        
        case $http_code in
            200|301|302)
                echo -e "${GREEN}OK${NC} (${http_code}, ${time_total}s)"
                ((healthy_apps++))
                response_times+=("$time_total")
                ;;
            000)
                echo -e "${RED}FALHOU${NC} (conexão)"
                ;;
            *)
                echo -e "${YELLOW}ALERTA${NC} (HTTP $http_code, ${time_total}s)"
                ;;
        esac
    done
    
    test_result $((${#SERVERS[@]} - healthy_apps)) "Aplicações saudáveis: $healthy_apps/${#SERVERS[@]}"
    
    # Calcular tempo médio de resposta se houver dados
    if [ ${#response_times[@]} -gt 0 ]; then
        local avg_time=$(printf "%.3f" $(echo "${response_times[*]}" | awk '{for(i=1;i<=NF;i++) sum+=$i; print sum/NF}'))
        info "Tempo médio de resposta: ${avg_time}s"
    fi
    
    echo
}

# 5. Validar logs de erro
validate_error_logs() {
    echo -e "${BLUE}=== 5. Verificação de Logs de Erro ===${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Verificar erros críticos nos logs
    local servers_with_errors=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "tail -100 /opt/tomcat/current/logs/catalina.out | grep -i 'SEVERE\|Exception.*Error\|OutOfMemory' | wc -l" \
        2>/dev/null | awk '/[0-9]+/ {if($0>0) count++} END {print count+0}')
    
    if [ "$servers_with_errors" -eq 0 ]; then
        test_result 0 "Nenhum erro crítico encontrado nos logs"
    else
        test_result 1 "$servers_with_errors servidores com erros críticos nos logs"
    fi
    
    # Verificar warnings excessivos
    local servers_with_warnings=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "tail -100 /opt/tomcat/current/logs/catalina.out | grep -i 'WARN' | wc -l" \
        2>/dev/null | awk '/[0-9]+/ {if($0>10) count++} END {print count+0}')
    
    if [ "$servers_with_warnings" -eq 0 ]; then
        test_result 0 "Nível de warnings aceitável"
    else
        test_result 1 "$servers_with_warnings servidores com warnings excessivos (>10)"
    fi
    
    echo
}

# 6. Validar diretórios custom
validate_custom_directories() {
    echo -e "${BLUE}=== 6. Integridade dos Diretórios Custom ===${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Verificar existência dos diretórios custom
    local custom_ok=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "[ -d /opt/tomcat/current/webapps/custom ] && echo 'OK' || echo 'MISSING'" \
        2>/dev/null | grep -c "OK" || echo 0)
    
    local custom_fsw_ok=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "[ -d /opt/tomcat/current/webapps/custom_fsw ] && echo 'OK' || echo 'MISSING'" \
        2>/dev/null | grep -c "OK" || echo 0)
    
    # Nota: não falha se custom dirs não existem, pois podem não ser necessários
    info "Diretório 'custom' presente: $custom_ok/${#SERVERS[@]} servidores"
    info "Diretório 'custom_fsw' presente: $custom_fsw_ok/${#SERVERS[@]} servidores"
    
    # Verificar permissões se existirem
    if [ "$custom_ok" -gt 0 ]; then
        local custom_perms_ok=$(ansible -i inventory.yml frontend_servers -m shell \
            -a "[ -d /opt/tomcat/current/webapps/custom ] && stat -c '%U:%G' /opt/tomcat/current/webapps/custom | grep -c 'tomcat:tomcat' || echo 0" \
            2>/dev/null | awk '{sum+=$0} END {print sum}')
        
        test_result $((custom_ok - custom_perms_ok)) "Permissões corretas no 'custom': $custom_perms_ok/$custom_ok"
    fi
    
    if [ "$custom_fsw_ok" -gt 0 ]; then
        local custom_fsw_perms_ok=$(ansible -i inventory.yml frontend_servers -m shell \
            -a "[ -d /opt/tomcat/current/webapps/custom_fsw ] && stat -c '%U:%G' /opt/tomcat/current/webapps/custom_fsw | grep -c 'tomcat:tomcat' || echo 0" \
            2>/dev/null | awk '{sum+=$0} END {print sum}')
        
        test_result $((custom_fsw_ok - custom_fsw_perms_ok)) "Permissões corretas no 'custom_fsw': $custom_fsw_perms_ok/$custom_fsw_ok"
    fi
    
    echo
}

# 7. Validar performance básica
validate_basic_performance() {
    echo -e "${BLUE}=== 7. Performance Básica ===${NC}"
    
    cd "$ANSIBLE_DIR"
    
    # Verificar uso de CPU
    local high_cpu_servers=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "top -bn1 | grep 'load average' | awk -F'load average:' '{print \$2}' | awk -F, '{print \$1}' | awk '{if(\$1>2.0) print \"HIGH\"; else print \"OK\"}'" \
        2>/dev/null | grep -c "HIGH" || echo 0)
    
    test_result $high_cpu_servers "CPU Load aceitável: $((${#SERVERS[@]} - high_cpu_servers))/${#SERVERS[@]}"
    
    # Verificar uso de memória
    local high_mem_servers=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "free | grep Mem | awk '{if((\$3/\$2)*100>80) print \"HIGH\"; else print \"OK\"}'" \
        2>/dev/null | grep -c "HIGH" || echo 0)
    
    test_result $high_mem_servers "Uso de memória aceitável: $((${#SERVERS[@]} - high_mem_servers))/${#SERVERS[@]}"
    
    # Verificar espaço em disco
    local low_disk_servers=$(ansible -i inventory.yml frontend_servers -m shell \
        -a "df /opt/tomcat | tail -1 | awk '{if(\$5+0>85) print \"LOW\"; else print \"OK\"}'" \
        2>/dev/null | grep -c "LOW" || echo 0)
    
    test_result $low_disk_servers "Espaço em disco suficiente: $((${#SERVERS[@]} - low_disk_servers))/${#SERVERS[@]}"
    
    echo
}

# Gerar relatório final
generate_final_report() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                        RELATÓRIO FINAL                          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    local success_rate=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
    
    echo "📊 Estatísticas:"
    echo "   • Total de testes: $TOTAL_TESTS"
    echo "   • Testes aprovados: $PASSED_TESTS"
    echo "   • Testes falharam: $FAILED_TESTS"
    echo "   • Taxa de sucesso: $success_rate%"
    echo
    
    if [ "$FAILED_TESTS" -eq 0 ]; then
        success "🎉 DEPLOYMENT VALIDADO COM SUCESSO!"
        success "   Todos os testes passaram. Sistema está operacional."
        echo
        return 0
    elif [ "$success_rate" -ge 80 ]; then
        warn "⚠️ DEPLOYMENT COM ALERTAS"
        warn "   $FAILED_TESTS teste(s) falharam, mas sistema está funcionando."
        warn "   Recomenda-se investigar as falhas."
        echo
        return 1
    else
        error "🚨 DEPLOYMENT COM PROBLEMAS CRÍTICOS"
        error "   $FAILED_TESTS teste(s) falharam. Sistema pode estar instável."
        error "   Ação imediata necessária!"
        echo
        return 2
    fi
}

# Validação rápida (subset dos testes)
quick_validation() {
    log "⚡ Validação rápida do deployment..."
    echo
    
    # Reset dos contadores
    TOTAL_TESTS=0
    PASSED_TESTS=0
    FAILED_TESTS=0
    
    # Testes essenciais apenas
    validate_ansible_connectivity
    validate_service_status
    validate_application_health
    
    generate_final_report
}

# Mostrar ajuda
show_help() {
    echo "Validador de Deployment - Ubuntu Environment"
    echo ""
    echo "Uso:"
    echo "  $0                    # Validação completa"
    echo "  $0 --quick           # Validação rápida"
    echo "  $0 --connectivity    # Apenas conectividade"
    echo "  $0 --health          # Apenas health check"
    echo "  $0 --help           # Esta ajuda"
    echo ""
    echo "Servidores configurados:"
    for i in "${!SERVERS[@]}"; do
        echo "  tomcat-$(printf "%02d" $((i+1))): ${SERVERS[$i]}"
    done
    echo ""
    echo "Códigos de saída:"
    echo "  0 = Todos os testes passaram"
    echo "  1 = Algumas falhas, mas sistema operacional" 
    echo "  2 = Falhas críticas, sistema instável"
}

# Função principal
main() {
    check_ubuntu
    
    case "${1:-}" in
        --quick|-q)
            quick_validation
            ;;
        --connectivity|-c)
            validate_ansible_connectivity
            validate_network_connectivity
            ;;
        --health|-h)
            validate_application_health
            ;;
        --help)
            show_help
            ;;
        "")
            validate_deployment
            ;;
        *)
            error "Opção inválida: $1"
            show_help
            exit 1
            ;;
    esac
}

# Executar função principal
main "$@"