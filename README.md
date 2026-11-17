# rekognitor-setup

Instaladores do **Rekognitor** para Windows, Linux e macOS. Cada um instala a solução completa numa única máquina: Kubernetes (k3s) + streamer, detect, vision, mqtt e redis.

📖 **[Manual de instalação completo](docs/MANUAL.md)** · 📄 **[versão em PDF](docs/MANUAL.pdf)**

## Instalação rápida

| Sistema | Instalar | Desinstalar |
| --- | --- | --- |
| **Windows 10/11** | duplo clique em `install-windows.cmd` | duplo clique em `uninstall-windows.cmd` |
| **Linux** | `./install.sh` | `./uninstall.sh` |
| **macOS** | `./install.sh` | `./uninstall.sh` |

1. Baixe este repositório (**Code → Download ZIP**) e extraia numa pasta local.
2. Rode o instalador do seu sistema.
3. Abra **<http://localhost:31881>** e entre com o `CLIENT_ID` e o `SECRET` mostrados no final da instalação.

Linux/macOS em uma linha:

```bash
curl -fsSL https://raw.githubusercontent.com/Rekognitor/rekognitor-setup/main/install.sh | bash
```

Requisitos mínimos: 2 CPUs (recomendado 4+), 4 GB de RAM (recomendado 8 GB), 15 GB de disco e acesso ao Docker Hub. Para verificar a máquina sem instalar nada: `./install.sh --check` ou `install-windows.cmd -Check`.

## Como funciona

| Sistema | Kubernetes |
| --- | --- |
| Windows | k3s numa distribuição WSL2 exclusiva (`Rekognitor`), mantida ligada por uma tarefa agendada no login |
| Linux | k3s nativo (serviço systemd) |
| macOS | k3d sobre o Docker Desktop, ou sobre o Colima instalado pelo Homebrew |

Os instaladores podem ser rodados de novo: rodar outra vez atualiza o Rekognitor. Eles registram tudo o que criam (`~/.rekognitor/state` ou `C:\ProgramData\Rekognitor\state.json`), e os desinstaladores removem somente isso.

## Para mantenedores

- `charts/` é uma cópia dos Helm charts do repositório `rekognitor.helm`, que é privado. Os segredos são substituídos por placeholders, e o instalador gera segredos novos em cada instalação. Para atualizar a cópia:

  ```bash
  tools/sync-charts.sh /caminho/para/rekognitor.helm
  ```

- `values/light/` define o perfil para máquinas com menos de 6 CPUs.
- As imagens do manual são saídas reais, renderizadas com `tools/screenshots.sh`. Depois de editar o manual, regenere o PDF com `tools/build-manual-pdf.sh`. Os dois precisam de podman ou docker.
- O CI (`.github/workflows/installer.yml`) roda os lints, a instalação → atualização → desinstalação completa num Ubuntu, e verificações de sintaxe no macOS (bash 3.2) e no Windows.
