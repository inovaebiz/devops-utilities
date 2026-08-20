<p align="center">
  <h1 align="center">Inova e-Business · DevOps Utilities</h1>
  <p align="center">
    Conjunto de utilitários e scripts de DevOps mantidos pela
    <strong>Inova e-Business</strong>.
  </p>
  <p align="center">
    <a href="https://github.com/inovaebiz/devops-utilities/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/inovaebiz/devops-utilities?color=blue"></a>
    <a href="https://github.com/inovaebiz/devops-utilities"><img alt="GitHub repo stars" src="https://img.shields.io/github/stars/inovaebiz/devops-utilities?color=yellow"></a>
    <a href="https://github.com/inovaebiz/devops-utilities"><img alt="GitHub last commit" src="https://img.shields.io/github/last-commit/inovaebiz/devops-utilities"></a>
    <a href="https://github.com/inovaebiz/devops-utilities/issues"><img alt="GitHub issues" src="https://img.shields.io/github/issues/inovaebiz/devops-utilities"></a>
    <a href="https://github.com/inovaebiz/devops-utilities/pulls"><img alt="GitHub pull requests" src="https://img.shields.io/github/issues-pr/inovaebiz/devops-utilities"></a>
    <img alt="Made with Bash" src="https://img.shields.io/badge/made%20with-Bash-4EAA25">
  </p>
</p>

---

## 📑 Sumário

- [Sobre o projeto](#-sobre-o-projeto)
- [Requisitos](#-requisitos)
- [Instalação](#-instalação)
- [Scripts disponíveis](#-scripts-disponíveis)
- [Aviso legal](#-aviso-legal)
- [Contribuindo](#-contribuindo)
- [Licença](#-licença)

---

## 💡 Sobre o projeto

Este repositório reúne scripts, ferramentas e automações de infraestrutura e
DevOps utilizados internamente pela **Inova e-Business**. Ele é disponibilizado
publicamente com o objetivo de compartilhar boas práticas e facilitar o
trabalho de outras equipes.

## 🧰 Requisitos

- **Linux** (ou ambiente compatível com `systemd` para os scripts de serviço)
- **Docker** instalado e em execução
- **Bash** 4+
- **curl** para baixar os scripts

## 🚀 Instalação

Este repositório usa um **gerenciador** (`install.sh`) que instala, rastreia,
atualiza e remove os scripts, além de informar quais estão desatualizados em
relação ao repositório.

### Instalando o gerenciador

Baixe e execute o menu interativo em uma única linha (o `sudo` já cobre a
instalação, sem erro de permissão):

```bash
curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh
```

### Comandos do gerenciador

```bash
sudo bash /tmp/install.sh list                    # lista scripts + status/versões
sudo bash /tmp/install.sh install docker-cleanup.sh
sudo bash /tmp/install.sh update                  # atualiza todos os instalados
sudo bash /tmp/install.sh update threat-scan.sh   # atualiza um script
sudo bash /tmp/install.sh remove threat-scan.sh
sudo bash /tmp/install.sh self-update             # atualiza o próprio gerenciador
```

> O gerenciador detecta automaticamente quando há uma nova versão dele mesmo,
> mostra a versão atual, a versão remota e as últimas mudanças (do git), e
> pergunta se deseja atualizar.

### Instalação direta (sem menu)

Você também pode baixar e instalar um script em uma única linha, sem o
gerenciador (o `sudo` vai antes do `bash`, nunca antes do `curl`):

```bash
curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh | sudo bash -s -- <script> [diretorio]
```

Exemplo com o `docker-cleanup.sh` (instala em `/usr/local/sbin` com `chmod 750`):

```bash
curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh | sudo bash -s -- docker-cleanup.sh
```

Ou instale em um diretório customizado:

```bash
curl -fsSL https://raw.githubusercontent.com/inovaebiz/devops-utilities/main/install.sh | sudo bash -s -- docker-cleanup.sh /opt/scripts
```

> ℹ️ O download é feito como usuário normal; apenas a instalação final usa
> `sudo` (que pode pedir sua senha). Sempre revise o conteúdo do script antes
> de executá-lo.

## 📦 Scripts disponíveis

| Script | Descrição | Instalação |
| --- | --- | --- |
| [`docker-cleanup.sh`](./docker-cleanup.sh) | Limpeza automática de imagens, containers parados, redes não utilizadas e cache de build do Docker, preservando sempre os volumes. | `curl -fsSL ...main/install.sh \| bash -s -- docker-cleanup.sh` |
| [`sys-update-checker.sh`](./sys-update-checker.sh) | Analisa pacotes, kernel e serviços que precisam de atualização e aplica as atualizações de forma segura após aceite (modo interativo ou `--yes`). | `curl -fsSL ...main/install.sh \| bash -s -- sys-update-checker.sh` |
| [`threat-scan.sh`](./threat-scan.sh) | Varredura somente-leitura que identifica indícios de vírus, worms, malwares, mineradores, backdoors e persistências suspeitas (processos, rede, cron, usuários, arquivos, kernel). | `curl -fsSL ...main/install.sh \| bash -s -- threat-scan.sh` |
| [`install.sh`](./install.sh) | Gerenciador/instalador: baixa, rastreia versões, atualiza e remove os scripts, com menu interativo e comandos de linha. | — |

## ⚖️ Aviso legal

> **Este é um projeto público de uso interno da Inova e-Business.**
>
> O código é fornecido "como está" (*as is*), sem garantias de qualquer tipo.
> A Inova e-Business **não se responsabiliza** pelo uso que terceiros façam
> deste repositório, nem por eventuais danos, perdas ou problemas decorrentes
> da sua utilização.
>
> O uso dos scripts e utilitários aqui presentes é de inteira
> responsabilidade de quem os utilizar.

## 🤝 Contribuindo

Este é um projeto público e colaborações são bem-vindas. Para contribuir:

1. Faça um *fork* do repositório.
2. Crie uma *branch* para sua alteração (`git checkout -b feature/minha-mudanca`).
3. Faça o *commit* das suas alterações (`git commit -m 'Adiciona minha mudança'`).
4. Envie para o seu *fork* (`git push origin feature/minha-mudanca`).
5. Abra um *Pull Request*.

## 📄 Licença

Distribuído sob a licença [MIT](./LICENSE).

---

<p align="center">
  Mantido com ❤️ pela <strong>Inova e-Business</strong>
</p>
