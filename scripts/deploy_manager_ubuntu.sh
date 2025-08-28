#!/bin/bash
# Deploy Manager Script for Ubuntu Environment

set -euo pipefail

# Configurações para Ubuntu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="/opt/ansible-deploys"
FSX_MOUNT="/mnt/ansible"
LOG_DIR="$ANSIBLE_DIR/logs"
OS_TYPE="ubuntu"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Verificar se está rodando no Ubuntu
check_ubuntu() {
    if [ ! -f /etc/lsb-release ] || ! grep -q "Ubuntu" /etc/lsb-release; then
        warn "Este script foi otimizado para Ubuntu"
        warn "OS detectado: $(lsb_release -d 2>/dev/null || echo 'Desconhecido')"
        read -p "Continuar mesmo assim? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
}

# Funções de log
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

# Verificar se FSx está montado
check_fsx_mount() {
    if ! mountpoint -q "$FSX_MOUNT"; then
        error "FSx não está montado em $FSX_MOUNT"
        echo ""
        info "Para montar o FSx, execute:"
        echo "sudo mount -t cifs //fs-xxxxx.fsx.us-east-1.amazonaws.com/share $FSX_MOUNT \\"
        echo "    -o username=admin,password=SuaSenha,uid=ubuntu,gid=ubuntu"
        return 1
    fi
    log "FSx mount verificado: $FSX_MOUNT"
    
    # Verificar se pode escrever no FSx
    if ! touch "$FSX_MOUNT/.test" 2>/dev/null; then
        warn "FSx montado mas sem permissão de escrita"
    else
        rm -f "$FSX_MOUNT/.test"
    fi
}

# Verificar dependências do Ubuntu
check_dependencies() {
    local missing_deps=()
    
    # Verificar Ansible
    if ! command -v ansible &> /dev/null; then
        missing_deps+=("ansible")
    fi
    
    # Verificar jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    # Verificar rsync
    if ! command -v rsync &> /dev/null; then
        missing_deps+=("rsync")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        error "Dependências faltando: ${missing_deps[*]}"
        info "Execute: sudo apt update && sudo apt install -y ${missing_deps[*]}"
        return 1
    fi
    
    log "Todas as dependências encontradas"
}

# Exibir informações do sistema Ubuntu
show_system_info() {
    echo -e "${BLUE}=== Informações do Sistema Ubuntu ===${NC}"
    echo "OS: $(lsb_release -d | cut -f2)"
    echo "Kernel: $(uname -r)"
    echo "Uptime: $(uptime -p)"
    echo "Memória: $(free -h | grep Mem | awk '{print $3 "/" $2}')"
    echo "Disco Ansible: $(df -h $ANSIBLE_DIR | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    if mountpoint -q "$FSX_MOUNT"; then
        echo "Disco FSx: $(df -h $FSX_MOUNT | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')"
    fi
    echo ""
}

# Listar updates disponíveis no FSx
list_updates() {
    echo -e "${BLUE}=== Updates Disponíveis no FSx (Ubuntu) ===${NC}"
    echo
    
    if [ ! -d "$FSX_MOUNT/staging" ]; then
        warn "Diretório staging não encontrado no FSx"
        info "Certifique-se de fazer upload dos updates primeiro"
        return 1
    fi
    
    # WAR Updates
    echo -e "${GREEN}📦 WAR Updates:${NC}"
    if find "$FSX_MOUNT/staging" -maxdepth 2 -name "war-*" -type d 2>/dev/null | grep -q .; then
        find "$FSX_MOUNT/staging" -maxdepth 2 -name "war-*" -type d -printf "  %P" -exec sh -c 'echo " ($(du -sh "$1" | cut -f1))"' _ {} \; 2>/dev/null | sort -r
    else
        echo "  Nenhum update WAR encontrado"
    fi
    echo
    
    # Version Updates
    echo -e "${GREEN}🔄 Version Updates:${NC}"
    if find "$FSX_MOUNT/staging" -maxdepth 2 -name "version-*" -type d 2>/dev/null | grep -q .; then
        find "$FSX_MOUNT/staging" -maxdepth 2 -name "version-*" -type d -printf "  %P" -exec sh -c 'echo " ($(du -sh "$1" | cut -f1))"' _ {} \; 2>/dev/null | sort -r
    else
        echo "  Nenhum update de versão encontrado"
    fi
    echo
    
    # Triggers pendentes
    if [ -d "$FSX_MOUNT/triggers" ] && ls "$FSX_MOUNT/triggers"/*.json >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Triggers Pendentes:${NC}"
        for trigger in "$FSX_MOUNT/triggers"/*.json; do
            [ -f "$trigger" ] || continue
            filename=$(basename "$trigger" .json)
            echo -e "  📋 ${CYAN}$filename${NC}"
            if command -v jq >/dev/null 2>&1; then
                echo "     Type: $(jq -r '.UpdateType' "$trigger")"
                echo "     Size: $(numfmt --to=iec "$(jq -r '.Size' "$trigger")" 2>/dev/null || echo "N/A")"
                echo "     User: $(jq -r '.User' "$trigger")"
                echo "     Time: $(jq -r '.Timestamp' "$trigger")"
                echo "     Machine: $(jq -r '.Machine' "$trigger")"
            fi
            echo
        done
    else
        echo -e "${CYAN}ℹ️  Nenhum trigger pendente${NC}"
    fi
}

# Health check do cluster Ubuntu
health_check() {
    log "Verificando saúde do cluster Ubuntu..."
    
    cd "$ANSIBLE_DIR"
    
    echo -e "${BLUE}=== Conectividade SSH ===${NC}"
    if ansible -i inventory.yml frontend_servers -m ping --one-line; then
        success "Conectividade SSH: OK"
    else
        error "Problemas de conectividade detectados"
    fi
    echo
    
    echo -e "${BLUE}=== Status do Tomcat ===${NC}"
    ansible -i inventory.yml frontend_servers -m shell -a "systemctl is-active tomcat && echo 'Status: OK'" --one-line
    echo
    
    echo -e "${BLUE}=== Espaço em Disco ===${NC}"
    ansible -i inventory.yml frontend_servers -m shell -a "df -h /opt/tomcat | tail -1 | awk '{print \"Tomcat: \" \$3 \"/\" \$2 \" (\" \$5 \")\"}'" --one-line
    echo
    
    echo -e "${BLUE}=== Memória e Load ===${NC}"
    ansible -i inventory.yml frontend_servers -m shell -a "free -h | grep Mem | awk '{print \"RAM: \" \$3 \"/\" \$2}' && uptime | awk '{print \"Load: \" \$(NF-2) \" \" \$(NF-1) \" \" \$NF}'" --one-line
    echo
    
    echo -e "${BLUE}=== Versão do Sistema ===${NC}"
    ansible -i inventory.yml frontend_servers -m shell -a "lsb_release -d | cut -f2 && uname -r" --one-line
    echo
    
    echo -e "${BLUE}=== Health Check das Aplicações ===${NC}"
    ansible -i inventory.yml frontend_servers -m shell -a "curl -k -s -o /dev/null -w 'HTTP: %{http_code}, Time: %{time_total}s' https://localhost:8080/totvs-menu 2>/dev/null || echo 'Health check falhou'" --one-line
}

# Deploy de WAR com validações Ubuntu
deploy_war() {
    local update_path=$1
    local full_path="$FSX_MOUNT/staging/$update_path"
    
    if [ ! -d "$full_path" ]; then
        error "Update não encontrado: $update_path"
        return 1
    fi
    
    # Validações pré-deploy
    log "Validando update WAR para Ubuntu..."
    
    if [ ! -d "$full_path/webapps" ]; then
        error "Diretório webapps não encontrado em $full_path"
        return 1
    fi
    
    local war_count=$(find "$full_path/webapps" -name "*.war" | wc -l)
    if [ "$war_count" -eq 0 ]; then
        error "Nenhum arquivo WAR encontrado"
        return 1
    fi
    
    info "Encontrados $war_count arquivos WAR para deploy"
    
    # Verificar espaço em disco nos servidores
    log "Verificando espaço em disco nos servidores Ubuntu..."
    cd "$ANSIBLE_DIR"
    if ! ansible -i inventory.yml frontend_servers -m shell -a "df /opt/tomcat | tail -1 | awk '{if(\$5+0 > 80) exit 1}'" >/dev/null; then
        warn "Alguns servidores com pouco espaço em disco (>80%)"
        read -p "Continuar mesmo assim? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
    fi
    
    log "Iniciando deploy de WAR Ubuntu: $update_path"
    
    # Preparar variáveis
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$LOG_DIR/deploy-war-ubuntu-$timestamp.log"
    
    # Executar playbook
    cd "$ANSIBLE_DIR"
    log "Executando playbook WAR para Ubuntu..."
    
    if ansible-playbook -i inventory.yml playbooks/update-war.yml \
        -e "update_source=$full_path" \
        -e "deploy_timestamp=$timestamp" \
        -e "os_type=ubuntu" \
        | tee "$log_file"; then
        
        success "Deploy WAR concluído com sucesso!"
        
        # Mover para histórico
        [ -d "$FSX_MOUNT/deployed" ] || mkdir -p "$FSX_MOUNT/deployed"
        mv "$full_path" "$FSX_MOUNT/deployed/$(basename "$update_path")-deployed-$timestamp"
        
        # Remover trigger correspondente
        rm -f "$FSX_MOUNT/triggers/"*"$(basename "$update_path")"*.json
        
        # Criar relatório de sucesso
        echo "$(date): WAR Deploy SUCCESS - $update_path" >> "$FSX_MOUNT/logs/ubuntu-deploys.log"
        
        info "Log detalhado: $log_file"
        
        return 0
    else
        error "Deploy falhou! Verifique o log: $log_file"
        echo "$(date): WAR Deploy FAILED - $update_path" >> "$FSX_MOUNT/logs/ubuntu-deploys.log"
        return 1
    fi
}

# Deploy de versão com validações Ubuntu
deploy_version() {
    local update_path=$1
    local full_path="$FSX_MOUNT/staging/$update_path"
    
    if [ ! -d "$full_path" ]; then
        error "Update não encontrado: $update_path"
        return 1
    fi
    
    # Validações críticas para deploy de versão
    log "Validando update de VERSÃO para Ubuntu..."
    
    local required_dirs=("webapps" "Datasul-report" "lib")
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$full_path/$dir" ]; then
            error "Diretório obrigatório não encontrado: $dir"
            return 1
        fi
    done
    
    # Mostrar tamanhos dos diretórios
    info "Tamanhos dos diretórios:"
    for dir in "${required_dirs[@]}"; do
        size=$(du -sh "$full_path/$dir" | cut -f1)
        echo "  - $dir: $size"
    done
    
    echo
    warn "🚨 ATENÇÃO: DEPLOY DE VERSÃO COMPLETA 🚨"
    warn "Esta operação irá atualizar TODOS os componentes:"
    warn "- webapps (incluindo todos os WARs)"
    warn "- Datasul-report (relatórios)"
    warn "- lib (bibliotecas)"
    warn ""
    warn "⚠️  IMPACTO: DOWNTIME PROLONGADO"
    warn "⚠️  RISCO: ALTO (alteração completa do sistema)"
    warn ""
    echo -e "${PURPLE}Servidores que serão atualizados (1 por vez):${NC}"
    cd "$ANSIBLE_DIR"
    ansible -i inventory.yml frontend_servers --list-hosts | grep -v "hosts ("
    echo
    
    read -p "Confirma o deploy de VERSÃO COMPLETA? Digite 'CONFIRMO': " confirmation
    if [ "$confirmation" != "CONFIRMO" ]; then
        log "Deploy cancelado pelo usuário"
        return 1
    fi
    
    # Verificação final de espaço
    log "Verificação final de espaço em disco..."
    if ! ansible -i inventory.yml frontend_servers -m shell -a "df /opt/tomcat | tail -1 | awk '{if(\$4 < 2097152) exit 1}'" >/dev/null; then
        error "Espaço insuficiente em alguns servidores (<2GB disponível)"
        return 1
    fi
    
    log "Iniciando deploy de VERSÃO Ubuntu: $update_path"
    
    # Preparar variáveis
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$LOG_DIR/deploy-version-ubuntu-$timestamp.log"
    
    # Executar playbook
    cd "$ANSIBLE_DIR"
    log "Executando playbook de VERSÃO para Ubuntu..."
    info "AVISO: Esta operação pode demorar 30-60 minutos"
    
    if ansible-playbook -i inventory.yml playbooks/update-version.yml \
        -e "update_source=$full_path" \
        -e "deploy_timestamp=$timestamp" \
        -e "os_type=ubuntu" \
        | tee "$log_file"; then
        
        success "🎉 Deploy de VERSÃO concluído com sucesso!"
        
        # Mover para histórico
        [ -d "$FSX_MOUNT/deployed" ] || mkdir -p "$FSX_MOUNT/deployed"
        mv "$full_path" "$FSX_MOUNT/deployed/$(basename "$update_path")-deployed-$timestamp"
        
        # Remover trigger correspondente
        rm -f "$FSX_MOUNT/triggers/"*"$(basename "$update_path")"*.json
        
        # Criar relatório de sucesso
        echo "$(date): VERSION Deploy SUCCESS - $update_path" >> "$FSX_MOUNT/logs/ubuntu-deploys.log"
        
        info "Log detalhado: $log_file"
        warn "IMPORTANTE: Teste completamente a aplicação antes de considerar o deploy finalizado!"
        
        return 0
    else
        error "Deploy de versão falhou! Verifique o log: $log_file"
        echo "$(date): VERSION Deploy FAILED - $update_path" >> "$FSX_MOUNT/logs/ubuntu-deploys.log"
        error "CRÍTICO: Sistema pode estar em estado inconsistente"
        warn "Considere executar rollback imediatamente!"
        return 1
    fi
}

# Executar rollback
execute_rollback() {
    warn "🚨 ROLLBACK DE EMERGÊNCIA 🚨"
    warn "Esta operação irá restaurar um backup anterior"
    echo
    
    cd "$ANSIBLE_DIR"
    if ansible-playbook -i inventory.yml playbooks/rollback.yml; then
        success "Rollback executado"
        echo "$(date): ROLLBACK executed via deploy-manager" >> "$FSX_MOUNT/logs/ubuntu-deploys.log"
    else
        error "Rollback falhou - verificação manual necessária"
    fi
}

# Ver logs recentes
view_logs() {
    echo -e "${BLUE}=== Logs Recentes (Ubuntu) ===${NC}"
    echo
    
    if [ ! -d "$LOG_DIR" ]; then
        warn "Diretório de logs não encontrado"
        return 1
    fi
    
    echo "Arquivos de log disponíveis:"
    ls -la "$LOG_DIR" | tail -10
    echo
    
    read -p "Ver conteúdo de algum log? (nome do arquivo ou Enter para voltar): " log_choice
    if [ -n "$log_choice" ] && [ -f "$LOG_DIR/$log_choice" ]; then
        echo -e "${BLUE}=== Conteúdo de $log_choice ===${NC}"
        
        # Usar less com cores se disponível
        if command -v less >/dev/null 2>&1; then
            less +G "$LOG_DIR/$log_choice"
        else
            tail -50 "$LOG_DIR/$log_choice"
        fi
    fi
}

# Menu principal Ubuntu
show_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    🚀 DEPLOY MANAGER UBUNTU 🚀                   ║${NC}"
    echo -e "${BLUE}║                   Tomcat Deployment Automation                  ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  OS: Ubuntu $(lsb_release -rs 2>/dev/null || echo 'Unknown')                                                    ║${NC}"
    echo -e "${BLUE}║  Ansible: /opt/ansible-deploys                                  ║${NC}"
    echo -e "${BLUE}║  FSx: /mnt/ansible                                               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}1.${NC} 📋 Listar updates disponíveis"
    echo -e "${CYAN}2.${NC} 🏥 Health check do cluster"
    echo -e "${CYAN}3.${NC} 📦 Deploy WAR"
    echo -e "${CYAN}4.${NC} 🔄 Deploy Versão (CRÍTICO)"
    echo -e "${CYAN}5.${NC} 🚨 Rollback de emergência"
    echo -e "${CYAN}6.${NC} 📄 Ver logs recentes"
    echo -e "${CYAN}7.${NC} ℹ️  Informações do sistema"
    echo -e "${CYAN}0.${NC} 🚪 Sair"
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
}

# Programa principal
main() {
    # Verificações iniciais
    check_ubuntu
    check_dependencies || exit 1
    check_fsx_mount || exit 1
    
    if [ $# -eq 0 ]; then
        # Modo interativo
        while true; do
            show_menu
            read -p "Escolha uma opção: " choice
            
            case $choice in
                1) 
                    clear
                    list_updates 
                    ;;
                2) 
                    clear
                    health_check 
                    ;;
                3) 
                    clear
                    list_updates
                    echo
                    read -p "Digite o path do WAR update (ex: war-2025-08-23_14-30-45): " war_path
                    if [ -n "$war_path" ]; then
                        deploy_war "$war_path"
                    fi
                    ;;
                4)
                    clear
                    list_updates
                    echo
                    read -p "Digite o path do VERSION update (ex: version-2025-08-20_09-15-30): " version_path
                    if [ -n "$version_path" ]; then
                        deploy_version "$version_path"
                    fi
                    ;;
                5)
                    clear
                    execute_rollback
                    ;;
                6)
                    clear
                    view_logs
                    ;;
                7)
                    clear
                    show_system_info
                    ;;
                0) 
                    log "Saindo do Deploy Manager Ubuntu..."
                    exit 0 
                    ;;
                *) 
                    error "Opção inválida!" 
                    ;;
            esac
            
            echo
            read -p "Pressione Enter para continuar..." -r
        done
    else
        # Modo comando
        case "$1" in
            "list") 
                list_updates 
                ;;
            "health") 
                health_check 
                ;;
            "deploy-war") 
                [ -z "$2" ] && { error "Uso: $0 deploy-war <path>"; exit 1; }
                deploy_war "$2" 
                ;;
            "deploy-version")
                [ -z "$2" ] && { error "Uso: $0 deploy-version <path>"; exit 1; }
                deploy_version "$2"
                ;;
            "rollback")
                execute_rollback
                ;;
            "info")
                show_system_info
                ;;
            *) 
                echo "Deploy Manager - Ubuntu Environment"
                echo
                echo "Uso:"
                echo "  $0                           # Modo interativo"
                echo "  $0 list                      # Listar updates"
                echo "  $0 health                    # Health check"
                echo "  $0 deploy-war <path>         # Deploy WAR"
                echo "  $0 deploy-version <path>     # Deploy versão"
                echo "  $0 rollback                  # Rollback"
                echo "  $0 info                      # Info do sistema"
                ;;
        esac
    fi
}

# Executar função principal
main "$@"