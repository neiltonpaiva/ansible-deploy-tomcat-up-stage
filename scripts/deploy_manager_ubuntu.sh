#!/bin/bash
# Deploy Manager Script for Ubuntu Environment - Simple Structure

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

# Listar updates disponíveis - ESTRUTURA SIMPLES
list_updates() {
    echo -e "${BLUE}=== Updates Disponíveis (Estrutura Simples) ===${NC}"
    echo
    
    # Verificar diretório staging
    if [ ! -d "$FSX_MOUNT/staging" ]; then
        warn "Diretório staging não encontrado no FSx"
        info "Criando estrutura básica..."
        mkdir -p "$FSX_MOUNT/staging/war"
        mkdir -p "$FSX_MOUNT/staging/version"/{webapps,Datasul-report,lib}
        return 1
    fi
    
    # WAR Updates
    echo -e "${GREEN}📦 WAR Updates:${NC}"
    if [ -d "$FSX_MOUNT/staging/war" ]; then
        local war_count=$(find "$FSX_MOUNT/staging/war" -name "*.war" -o -name "*.WAR" 2>/dev/null | wc -l)
        if [ "$war_count" -gt 0 ]; then
            echo "  📁 Diretório: $FSX_MOUNT/staging/war/"
            echo "  📦 Arquivos disponíveis:"
            find "$FSX_MOUNT/staging/war" \( -name "*.war" -o -name "*.WAR" \) -printf "    • %f (%s bytes)\n" 2>/dev/null
            echo "  📊 Total: $war_count arquivo(s) WAR"
            local war_size=$(du -sh "$FSX_MOUNT/staging/war" 2>/dev/null | cut -f1)
            echo "  💾 Tamanho total: $war_size"
        else
            echo "  📭 Nenhum arquivo WAR encontrado em $FSX_MOUNT/staging/war/"
        fi
    else
        echo "  ❌ Diretório war não encontrado"
        info "Criando: mkdir -p $FSX_MOUNT/staging/war"
        mkdir -p "$FSX_MOUNT/staging/war"
    fi
    echo
    
    # Version Updates  
    echo -e "${GREEN}🔄 Version Updates:${NC}"
    if [ -d "$FSX_MOUNT/staging/version" ]; then
        echo "  📁 Diretório: $FSX_MOUNT/staging/version/"
        
        # Verificar webapps
        local webapps_count=0
        if [ -d "$FSX_MOUNT/staging/version/webapps" ]; then
            webapps_count=$(find "$FSX_MOUNT/staging/version/webapps" \( -name "*.war" -o -name "*.WAR" \) 2>/dev/null | wc -l)
            echo "    📦 webapps/: $webapps_count WARs"
        fi
        
        # Verificar Datasul-report
        local datasul_count=0
        if [ -d "$FSX_MOUNT/staging/version/Datasul-report" ]; then
            datasul_count=$(find "$FSX_MOUNT/staging/version/Datasul-report" -type f 2>/dev/null | wc -l)
            echo "    📋 Datasul-report/: $datasul_count arquivos"
        fi
        
        # Verificar lib
        local lib_count=0
        if [ -d "$FSX_MOUNT/staging/version/lib" ]; then
            lib_count=$(find "$FSX_MOUNT/staging/version/lib" -name "*.jar" 2>/dev/null | wc -l)
            echo "    📚 lib/: $lib_count JARs"
        fi
        
        # Status geral
        local total_files=$((webapps_count + datasul_count + lib_count))
        if [ "$total_files" -gt 0 ]; then
            local version_size=$(du -sh "$FSX_MOUNT/staging/version" 2>/dev/null | cut -f1)
            echo "  📊 Total: $total_files arquivo(s), $version_size"
            echo "  ✅ Pronto para deploy de versão"
        else
            echo "  📭 Nenhum arquivo encontrado para deploy de versão"
        fi
    else
        echo "  ❌ Diretório version não encontrado"
        info "Criando estrutura: mkdir -p $FSX_MOUNT/staging/version/{webapps,Datasul-report,lib}"
        mkdir -p "$FSX_MOUNT/staging/version"/{webapps,Datasul-report,lib}
    fi
    echo
    
    # Instruções
    echo -e "${CYAN}💡 Como usar:${NC}"
    echo "  Para WAR: Salve arquivos .war/.WAR em $FSX_MOUNT/staging/war/"
    echo "  Para Versão: Organize arquivos em $FSX_MOUNT/staging/version/{webapps,Datasul-report,lib}/"
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
    
    echo -e "${BLUE}=== Health Check das Aplicações ===${NC}"
    ansible -i inventory.yml frontend_servers -m shell -a "curl -k -s -o /dev/null -w 'HTTP: %{http_code}, Time: %{time_total}s' https://localhost:8080/totvs-menu 2>/dev/null || echo 'Health check falhou'" --one-line
}

# Deploy de WAR com estrutura simples
deploy_war() {
    log "🚀 Deploy WAR (Estrutura Simples)"
    
    # Verificar se diretório war existe
    if [ ! -d "$FSX_MOUNT/staging/war" ]; then
        error "Diretório WAR não encontrado: $FSX_MOUNT/staging/war"
        info "Execute 'list' para criar a estrutura"
        return 1
    fi
    
    # Verificar se há arquivos WAR
    local war_count=$(find "$FSX_MOUNT/staging/war" \( -name "*.war" -o -name "*.WAR" \) 2>/dev/null | wc -l)
    if [ "$war_count" -eq 0 ]; then
        error "Nenhum arquivo WAR encontrado em $FSX_MOUNT/staging/war/"
        info "Copie seus arquivos .war ou .WAR para o diretório antes de executar o deploy"
        return 1
    fi
    
    # Mostrar arquivos que serão deployados
    echo -e "${CYAN}📦 Arquivos que serão deployados:${NC}"
    find "$FSX_MOUNT/staging/war" \( -name "*.war" -o -name "*.WAR" \) -printf "  • %f (%s bytes)\n" 2>/dev/null
    echo "  📊 Total: $war_count arquivo(s)"
    echo
    
    # Validações pré-deploy
    log "Validando ambiente para deploy WAR..."
    
    # Verificar conectividade
    cd "$ANSIBLE_DIR"
    if ! ansible -i inventory.yml frontend_servers -m ping >/dev/null 2>&1; then
        error "Falha na conectividade com os servidores"
        return 1
    fi
    
    # Verificar espaço em disco
    if ! ansible -i inventory.yml frontend_servers -m shell -a "df /opt/tomcat | tail -1 | awk '{if(\$5+0 > 85) exit 1}'" >/dev/null 2>&1; then
        warn "Alguns servidores com pouco espaço em disco (>85%)"
        read -p "Continuar mesmo assim? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
    fi
    
    # Confirmação
    echo -e "${YELLOW}⚠️ CONFIRMAÇÃO DE DEPLOY WAR${NC}"
    echo "  • Arquivos: $war_count WARs"
    echo "  • Servidores: 2 simultâneos (7 total)"
    echo "  • Preservação: custom + custom_fsw"
    echo "  • Tempo estimado: 5-10 minutos"
    echo
    read -p "🎯 Confirma o deploy? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Deploy cancelado pelo usuário"
        return 1
    fi
    
    # Executar deploy
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$LOG_DIR/deploy-war-simple-$timestamp.log"
    
    log "Executando playbook WAR (estrutura simples)..."
    
    if ansible-playbook -i inventory.yml playbooks/update-war.yml \
        -e "deploy_timestamp=$timestamp" \
        | tee "$log_file"; then
        
        success "🎉 Deploy WAR concluído com sucesso!"
        echo
        info "✅ Próximos passos recomendados:"
        info "  1. Executar validação: ./scripts/validate-deployment.sh --quick"
        info "  2. Verificar logs: tail -f $log_file"
        info "  3. Testar aplicação manualmente"
        echo
        return 0
    else
        error "❌ Deploy falhou! Verifique o log: $log_file"
        echo
        warn "🔧 Para rollback:"
        warn "  ./deploy-manager.sh rollback"
        return 1
    fi
}

# Deploy de versão com estrutura simples
deploy_version() {
    log "🚀 Deploy VERSÃO (Estrutura Simples)"
    
    # Verificar se diretório version existe
    if [ ! -d "$FSX_MOUNT/staging/version" ]; then
        error "Diretório VERSION não encontrado: $FSX_MOUNT/staging/version"
        info "Execute 'list' para criar a estrutura"
        return 1
    fi
    
    # Verificar subdiretórios obrigatórios
    local missing_dirs=()
    for dir in webapps Datasul-report lib; do
        if [ ! -d "$FSX_MOUNT/staging/version/$dir" ]; then
            missing_dirs+=("$dir")
        fi
    done
    
    if [ ${#missing_dirs[@]} -ne 0 ]; then
        error "Subdiretórios obrigatórios não encontrados: ${missing_dirs[*]}"
        info "Estrutura necessária:"
        info "  $FSX_MOUNT/staging/version/webapps/"
        info "  $FSX_MOUNT/staging/version/Datasul-report/"  
        info "  $FSX_MOUNT/staging/version/lib/"
        return 1
    fi
    
    # Verificar conteúdo
    local webapps_count=$(find "$FSX_MOUNT/staging/version/webapps" \( -name "*.war" -o -name "*.WAR" \) 2>/dev/null | wc -l)
    local datasul_count=$(find "$FSX_MOUNT/staging/version/Datasul-report" -type f 2>/dev/null | wc -l)
    local lib_count=$(find "$FSX_MOUNT/staging/version/lib" -name "*.jar" 2>/dev/null | wc -l)
    local total_files=$((webapps_count + datasul_count + lib_count))
    
    if [ "$total_files" -eq 0 ]; then
        error "Nenhum arquivo encontrado nos diretórios de versão"
        return 1
    fi
    
    # Mostrar conteúdo que será deployado
    echo -e "${CYAN}📦 Conteúdo que será deployado:${NC}"
    echo "  📦 webapps/: $webapps_count WARs"
    echo "  📋 Datasul-report/: $datasul_count arquivos"  
    echo "  📚 lib/: $lib_count JARs"
    echo "  📊 Total: $total_files arquivos"
    echo
    
    # Alertas críticos
    echo -e "${RED}🚨 ATENÇÃO: DEPLOY DE VERSÃO COMPLETA 🚨${NC}"
    echo -e "${RED}Esta operação irá substituir TODOS os componentes:${NC}"
    echo "  • webapps (incluindo todos os WARs)"
    echo "  • Datasul-report (relatórios)"  
    echo "  • lib (bibliotecas)"
    echo
    echo -e "${YELLOW}⚠️  IMPACTOS:${NC}"
    echo "  • DOWNTIME PROLONGADO (15+ minutos)"
    echo "  • RISCO ALTO (alteração completa do sistema)"
    echo "  • Deploy SEQUENCIAL (1 servidor por vez)"
    echo
    echo -e "${GREEN}🔒 PRESERVAÇÃO:${NC}"
    echo "  • custom/ será preservado"
    echo "  • custom_fsw/ será preservado"
    echo "  • Backup completo será criado"
    echo
    
    # Confirmação crítica
    read -p "Confirma o deploy de VERSÃO COMPLETA? Digite 'CONFIRMO': " confirmation
    if [ "$confirmation" != "CONFIRMO" ]; then
        log "Deploy cancelado pelo usuário"
        return 1
    fi
    
    # Verificação final de espaço
    log "Verificação final de espaço em disco..."
    if ! ansible -i inventory.yml frontend_servers -m shell -a "df /opt/tomcat | tail -1 | awk '{if(\$4 < 2097152) exit 1}'" >/dev/null 2>&1; then
        error "Espaço insuficiente em alguns servidores (<2GB disponível)"
        return 1
    fi
    
    # Executar deploy
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$LOG_DIR/deploy-version-simple-$timestamp.log"
    
    log "Executando playbook VERSÃO (estrutura simples)..."
    info "AVISO: Esta operação pode demorar 30-60 minutos"
    
    if ansible-playbook -i inventory.yml playbooks/update-version.yml \
        -e "deploy_timestamp=$timestamp" \
        | tee "$log_file"; then
        
        success "🎉 Deploy de VERSÃO concluído com sucesso!"
        echo
        info "✅ Próximos passos OBRIGATÓRIOS:"
        info "  1. Testar aplicação completamente"
        info "  2. Verificar se custom/custom_fsw funcionam"
        info "  3. Monitorar logs por 1+ hora"
        info "  4. Validar performance"
        echo
        warn "📄 Log detalhado: $log_file"
        return 0
    else
        error "❌ Deploy de versão falhou! CRÍTICO!"
        error "Sistema pode estar em estado inconsistente"
        echo
        warn "🚨 AÇÃO IMEDIATA:"
        warn "  1. Verificar log: $log_file"
        warn "  2. Considerar rollback: ./deploy-manager.sh rollback"
        warn "  3. Não fazer novos deploys até resolver!"
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
        echo "$(date): ROLLBACK executed via deploy-manager" >> "$FSX_MOUNT/logs/deploy-history.log" 2>/dev/null || true
    else
        error "Rollback falhou - verificação manual necessária"
    fi
}

# Ver logs recentes
view_logs() {
    echo -e "${BLUE}=== Logs Recentes ===${NC}"
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
    echo -e "${BLUE}║                Estrutura Simples - Sem Timestamps               ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  WAR: /mnt/ansible/staging/war/*.WAR                            ║${NC}"
    echo -e "${BLUE}║  VERSION: /mnt/ansible/staging/version/{webapps,Datasul,lib}/   ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}1.${NC} 📋 Listar updates disponíveis"
    echo -e "${CYAN}2.${NC} 🏥 Health check do cluster"
    echo -e "${CYAN}3.${NC} 📦 Deploy WAR (estrutura simples)"
    echo -e "${CYAN}4.${NC} 🔄 Deploy Versão (estrutura simples - CRÍTICO)"
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
                    deploy_war
                    ;;
                4)
                    clear
                    deploy_version
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
                    log "Saindo do Deploy Manager..."
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
                deploy_war
                ;;
            "deploy-version")
                deploy_version
                ;;
            "rollback")
                execute_rollback
                ;;
            "info")
                show_system_info
                ;;
            *) 
                echo "Deploy Manager - Ubuntu Environment (Estrutura Simples)"
                echo
                echo "Uso:"
                echo "  $0                    # Modo interativo"
                echo "  $0 list              # Listar updates"
                echo "  $0 health            # Health check"
                echo "  $0 deploy-war        # Deploy WAR"
                echo "  $0 deploy-version    # Deploy versão"
                echo "  $0 rollback          # Rollback"
                echo "  $0 info              # Info do sistema"
                echo ""
                echo "Estrutura FSx:"
                echo "  WAR: $FSX_MOUNT/staging/war/*.WAR"
                echo "  VERSION: $FSX_MOUNT/staging/version/{webapps,Datasul-report,lib}/"
                ;;
        esac
    fi
}

# Executar função principal
main "$@"