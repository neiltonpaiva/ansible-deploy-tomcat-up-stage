#!/bin/bash
# Quick WAR Deploy Script - Ubuntu
# Localização: /home/ubuntu/scripts/quick-war.sh

set -euo pipefail

# Configurações
ANSIBLE_DIR="/opt/ansible-deploys"
FSX_MOUNT="/mnt/ansible"

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Funções de log
log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
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

# Verificar pré-requisitos
check_prerequisites() {
    # Verificar se Ansible dir existe
    if [ ! -d "$ANSIBLE_DIR" ]; then
        error "Diretório Ansible não encontrado: $ANSIBLE_DIR"
        return 1
    fi
    
    # Verificar se FSx está montado
    if ! mountpoint -q "$FSX_MOUNT" 2>/dev/null; then
        error "FSx não está montado em $FSX_MOUNT"
        return 1
    fi
    
    # Verificar se deploy-manager existe
    if [ ! -f "$ANSIBLE_DIR/scripts/deploy-manager.sh" ]; then
        error "Script deploy-manager não encontrado"
        return 1
    fi
    
    return 0
}

# Listar updates WAR disponíveis rapidamente
list_war_updates() {
    echo -e "${BLUE}=== Updates WAR Disponíveis ===${NC}"
    echo
    
    if [ ! -d "$FSX_MOUNT/staging" ]; then
        warn "Nenhum update encontrado no FSx"
        return 1
    fi
    
    # Encontrar updates WAR
    local war_updates=()
    while IFS= read -r -d '' update; do
        war_updates+=("$(basename "$update")")
    done < <(find "$FSX_MOUNT/staging" -maxdepth 1 -name "war-*" -type d -print0 2>/dev/null)
    
    if [ ${#war_updates[@]} -eq 0 ]; then
        warn "Nenhum update WAR encontrado"
        echo
        info "Para fazer upload, use o script Windows:"
        info "  upload-to-fsx.ps1 -UpdateType \"war\" -SourcePath \"C:\\path\\to\\wars\""
        return 1
    fi
    
    echo "📦 Updates encontrados:"
    for i in "${!war_updates[@]}"; do
        local update="${war_updates[$i]}"
        local size=$(du -sh "$FSX_MOUNT/staging/$update" 2>/dev/null | cut -f1 || echo "?")
        echo "  $((i+1)). $update ($size)"
    done
    echo
}

# Deploy rápido com seleção
quick_deploy() {
    log "🚀 Quick WAR Deploy iniciado"
    echo
    
    # Verificar pré-requisitos
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Listar updates
    if ! list_war_updates; then
        exit 1
    fi
    
    # Se foi passado parâmetro, usar diretamente
    local selected_update=""
    if [ -n "${1:-}" ]; then
        selected_update="$1"
        if [ ! -d "$FSX_MOUNT/staging/$selected_update" ]; then
            error "Update não encontrado: $selected_update"
            exit 1
        fi
    else
        # Seleção interativa
        read -p "Digite o nome do update WAR (ou Enter para listar novamente): " selected_update
        
        if [ -z "$selected_update" ]; then
            list_war_updates
            read -p "Digite o nome do update: " selected_update
        fi
        
        if [ -z "$selected_update" ]; then
            error "Nenhum update selecionado"
            exit 1
        fi
    fi
    
    # Verificar se update existe
    if [ ! -d "$FSX_MOUNT/staging/$selected_update" ]; then
        error "Update não encontrado: $selected_update"
        exit 1
    fi
    
    # Mostrar informações do update
    local update_size=$(du -sh "$FSX_MOUNT/staging/$selected_update" | cut -f1)
    local war_count=$(find "$FSX_MOUNT/staging/$selected_update/webapps" -name "*.war" 2>/dev/null | wc -l)
    
    echo -e "${CYAN}📋 Detalhes do Deploy:${NC}"
    echo "  • Update: $selected_update"
    echo "  • Tamanho: $update_size"
    echo "  • Arquivos WAR: $war_count"
    echo "  • Servidores: 7 (2 simultâneos)"
    echo "  • Tempo estimado: 5-10 minutos"
    echo
    
    # Confirmação
    read -p "🎯 Confirma o deploy? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Deploy cancelado pelo usuário"
        exit 0
    fi
    
    # Executar deploy
    log "Executando deploy WAR via deploy-manager..."
    cd "$ANSIBLE_DIR"
    
    if ./scripts/deploy-manager.sh deploy-war "$selected_update"; then
        echo
        echo -e "${GREEN}🎉 DEPLOY WAR CONCLUÍDO COM SUCESSO!${NC}"
        echo
        info "✅ Próximos passos recomendados:"
        info "  1. Executar validação: quick-health.sh"
        info "  2. Verificar logs: tail -f /opt/ansible-deploys/logs/ansible.log"
        info "  3. Testar aplicação manualmente"
    else
        echo
        error "❌ Deploy falhou! Verificar logs e considerar rollback."
        echo
        warn "🔧 Para rollback:"
        warn "  ./deploy-manager.sh rollback"
        exit 1
    fi
}

# Auto-deploy (busca o update mais recente)
auto_deploy() {
    log "🤖 Auto WAR Deploy (último update)"
    
    if ! check_prerequisites; then
        exit 1
    fi
    
    # Encontrar update mais recente
    local latest_update=$(find "$FSX_MOUNT/staging" -maxdepth 1 -name "war-*" -type d -printf "%T@ %f\n" 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2)
    
    if [ -z "$latest_update" ]; then
        error "Nenhum update WAR encontrado para auto-deploy"
        exit 1
    fi
    
    log "Update mais recente encontrado: $latest_update"
    
    # Deploy direto sem confirmação interativa
    quick_deploy "$latest_update"
}

# Mostrar status atual
show_status() {
    echo -e "${BLUE}=== Status Quick WAR Deploy ===${NC}"
    echo
    
    # Status dos pré-requisitos
    echo "🔍 Verificando pré-requisitos..."
    if check_prerequisites; then
        echo -e "  ✅ Pré-requisitos: ${GREEN}OK${NC}"
    else
        echo -e "  ❌ Pré-requisitos: ${RED}FALHOU${NC}"
        return 1
    fi
    
    # Status do cluster
    echo "🏥 Status do cluster:"
    if command -v ansible >/dev/null; then
        cd "$ANSIBLE_DIR"
        local active_servers=$(ansible -i inventory.yml frontend_servers -m ping --one-line 2>/dev/null | grep -c "SUCCESS" || echo 0)
        echo -e "  📡 Servidores acessíveis: ${GREEN}$active_servers/7${NC}"
        
        local tomcat_active=$(ansible -i inventory.yml frontend_servers -m shell -a "systemctl is-active tomcat" 2>/dev/null | grep -c "active" || echo 0)
        echo -e "  🚀 Tomcat ativo: ${GREEN}$tomcat_active/7${NC}"
    else
        echo -e "  ❌ Ansible não disponível"
    fi
    
    # Updates disponíveis
    echo
    echo "📦 Updates disponíveis:"
    local war_count=$(find "$FSX_MOUNT/staging" -maxdepth 1 -name "war-*" -type d 2>/dev/null | wc -l)
    if [ "$war_count" -gt 0 ]; then
        echo -e "  🎯 WAR updates: ${GREEN}$war_count${NC}"
        find "$FSX_MOUNT/staging" -maxdepth 1 -name "war-*" -type d -printf "     • %f\n" 2>/dev/null | head -3
        if [ "$war_count" -gt 3 ]; then
            echo "     • ... e mais $((war_count - 3))"
        fi
    else
        echo -e "  📭 WAR updates: ${YELLOW}0${NC}"
    fi
    
    echo
}

# Mostrar ajuda
show_help() {
    echo -e "${BLUE}Quick WAR Deploy - Ubuntu Environment${NC}"
    echo
    echo "Atalho rápido para deploy de WARs com interface simplificada."
    echo
    echo "Uso:"
    echo "  $0                    # Deploy interativo"
    echo "  $0 <war-update>       # Deploy direto"
    echo "  $0 --auto            # Auto-deploy (último update)"
    echo "  $0 --status          # Mostrar status"
    echo "  $0 --list            # Listar updates disponíveis"
    echo "  $0 --help           # Esta ajuda"
    echo
    echo "Exemplos:"
    echo "  $0                              # Menu interativo"
    echo "  $0 war-2025-08-26_14-30-15     # Deploy específico"
    echo "  $0 --auto                       # Deploy automático"
    echo
    echo -e "${CYAN}💡 Dicas:${NC}"
    echo "  • Use 'quick-health.sh' após o deploy para validar"
    echo "  • Logs detalhados: tail -f /opt/ansible-deploys/logs/ansible.log"
    echo "  • Para rollback: deploy-manager.sh rollback"
}

# Função principal
main() {
    case "${1:-}" in
        --auto|-a)
            auto_deploy
            ;;
        --status|-s)
            show_status
            ;;
        --list|-l)
            check_prerequisites || exit 1
            list_war_updates
            ;;
        --help|-h)
            show_help
            ;;
        "")
            quick_deploy
            ;;
        *)
            quick_deploy "$1"
            ;;
    esac
}

# Trap para limpeza
cleanup() {
    echo
    log "Operação interrompida pelo usuário"
    exit 130
}

trap cleanup SIGINT SIGTERM

# Executar
main "$@"