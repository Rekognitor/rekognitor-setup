# rekognitor-setup

Instaladores do **Rekognitor** para Windows, Linux e macOS. Cada um instala a solução completa numa única máquina: Kubernetes **k0s** (a mesma versão em todos os sistemas) + streamer, detect, vision, mqtt e redis.

📖 **[Manual de instalação completo](docs/MANUAL.md)** · 📄 **[versão em PDF](docs/MANUAL.pdf)**

## Instalação rápida

| Sistema | Instalar | Desinstalar |
| --- | --- | --- |
| **Windows 10/11** | duplo clique em `install-windows.cmd` | duplo clique em `uninstall-windows.cmd` |
| **Linux** | `./install.sh` | `./uninstall.sh` |
| **macOS** | `./install.sh` | `./uninstall.sh` |

1. Tenha em mãos o `CLIENT_ID` e o `SECRET` fornecidos pela Rekognitor.
2. Baixe este repositório (**Code → Download ZIP**) e extraia numa pasta local.
3. Rode o instalador do seu sistema e digite as credenciais quando ele pedir. O que você digita não aparece na tela.
4. Abra **<http://localhost:31881>** e entre com as mesmas credenciais.

Linux/macOS em uma linha:

```bash
curl -fsSL https://raw.githubusercontent.com/Rekognitor/rekognitor-setup/main/install.sh | bash
```

Requisitos mínimos: 2 CPUs (recomendado 4+), 4 GB de RAM (recomendado 8 GB), 15 GB de disco e acesso ao Docker Hub. Para verificar a máquina sem instalar nada: `./install.sh --check` ou `install-windows.cmd -Check`.

## Como funciona

Todos usam o k0s v1.37.1+k0s.0, a versão em que o CI do `rekognitor.helm` valida os charts:

| Sistema | Onde o k0s roda |
| --- | --- |
| Linux | nativo (serviço systemd `k0scontroller`) |
| Windows | nativo numa distribuição WSL2 exclusiva (`Rekognitor`), mantida ligada por uma tarefa agendada no login |
| macOS | no contêiner oficial `k0sproject/k0s`, sobre o Docker Desktop ou o Colima instalado pelo Homebrew |

Portas iguais em todos os sistemas: interface **31881**, MQTT **31883** e MQTT/WebSocket **31882**.

Os instaladores podem ser rodados de novo: rodar outra vez atualiza o Rekognitor. Eles registram tudo o que criam (`~/.rekognitor/state` ou `C:\ProgramData\Rekognitor\state.json`), e os desinstaladores removem somente isso.

## Para mantenedores

- `charts/` é uma cópia dos Helm charts do repositório `rekognitor.helm`, que é privado. Os segredos são substituídos por placeholders. O instalador pede o `CLIENT_ID` e o `SECRET` ao usuário, sem eco, e os grava no Secret `rekognitor-credentials` do k0s, de onde o streamer lê (`credentials.existingSecret`). Para atualizar a cópia:

  ```bash
  tools/sync-charts.sh /caminho/para/rekognitor.helm
  ```

- `values/light/` define o perfil para máquinas com menos de 6 CPUs.
- As imagens do manual são saídas reais, renderizadas com `tools/screenshots.sh`. Depois de editar o manual, regenere o PDF com `tools/build-manual-pdf.sh`. Os dois precisam de podman ou docker.
- O CI (`.github/workflows/installer.yml`) roda os lints, a instalação → atualização → desinstalação completa num Ubuntu, e verificações de sintaxe no macOS (bash 3.2) e no Windows.
