<p align="center">
  <h1 align="center">Inova e-Business · DevOps Utilities</h1>
  <p align="center">
    Conjunto de utilitários e scripts de DevOps mantidos pela
    <strong>Inova e-Business</strong>.
  </p>
  <p align="center">
    <a href="https://github.com/inovaebiz/devops-utilities/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/inovaebiz/devops-utilities"></a>
    <a href="https://github.com/inovaebiz/devops-utilities"><img alt="GitHub repo stars" src="https://img.shields.io/github/stars/inovaebiz/devops-utilities"></a>
    <a href="https://github.com/inovaebiz/devops-utilities/issues"><img alt="GitHub issues" src="https://img.shields.io/github/issues/inovaebiz/devops-utilities"></a>
    <a href="https://github.com/inovaebiz/devops-utilities/pulls"><img alt="GitHub pull requests" src="https://img.shields.io/github/issues-pr/inovaebiz/devops-utilities"></a>
  </p>
</p>

---

## Requisitos

- **Linux** (ou ambiente compatível com `systemd` para os scripts de serviço)
- **Docker** instalado e em execução
- **Bash** 4+

## Sobre o projeto

Este repositório reúne scripts, ferramentas e automações de infraestrutura e
DevOps utilizados internamente pela **Inova e-Business**. Ele é disponibilizado
publicamente com o objetivo de compartilhar boas práticas e facilitar o
trabalho de outras equipes.

## Conteúdo

| Arquivo | Descrição |
| --- | --- |
| [`docker-cleanup.sh`](./docker-cleanup.sh) | Script para limpeza automática de imagens, containers parados, redes não utilizadas e cache de build do Docker, preservando sempre os volumes. |

## Aviso legal

> **Este é um projeto público de uso interno da Inova e-Business.**
>
> O código é fornecido "como está" (*as is*), sem garantias de qualquer tipo.
> A Inova e-Business **não se responsabiliza** pelo uso que terceiros façam
> deste repositório, nem por eventuais danos, perdas ou problemas decorrentes
> da sua utilização.
>
> O uso dos scripts e utilitários aqui presentes é de inteira
> responsabilidade de quem os utilizar.

## Contribuindo

Este é um projeto público e colaborações são bem-vindas. Para contribuir:

1. Faça um *fork* do repositório.
2. Crie uma *branch* para sua alteração (`git checkout -b feature/minha-mudanca`).
3. Faça o *commit* das suas alterações (`git commit -m 'Adiciona minha mudança'`).
4. Envie para o seu *fork* (`git push origin feature/minha-mudanca`).
5. Abra um *Pull Request*.

## Licença

Distribuído sob a licença [MIT](./LICENSE).

---

<p align="center">
  Mantido com ❤️ pela <strong>Inova e-Business</strong>
</p>
