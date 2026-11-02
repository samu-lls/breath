# Breath

Otimizador para Windows 10 e 11, com interface gráfica, em português.

Você escolhe o que aplicar, cada ajuste explica o que faz e indica o risco, e **tudo pode ser revertido**: antes de alterar qualquer coisa, o Breath guarda o valor original.

## Como usar

1. Baixe o [`dist/breath.cmd`](dist/breath.cmd).
2. Dê dois cliques e aceite o pedido de administrador.
3. Marque os ajustes (ou clique em **Recomendados**) e depois em **Aplicar**.
4. Reinicie o PC.

> O Windows pode mostrar "O Windows protegeu o computador", porque o arquivo não é assinado. Clique em **Mais informações → Executar assim mesmo**.

### Modo simulação

Para ver o que seria alterado sem mudar nada, abra o Prompt de Comando na pasta do arquivo e rode:

```
breath.cmd -DryRun
```

## Categorias

| Categoria | Exemplos |
|---|---|
| Geral | Prioridade da janela em primeiro plano, apps em segundo plano, notificações, Modo de Jogo |
| Energia | Plano "Breath Desempenho", Power Throttling, hibernação |
| Teclado e Mouse | Aceleração do mouse, repetição de teclas, suspensão USB |
| GPU | HAGS, ajustes específicos para NVIDIA, AMD e Intel (só aparecem para a sua placa) |
| CPU | Core parking, mitigações e SmartScreen (alto risco) |
| Memória | svchost ajustado à RAM, compressão de memória, SysMain |
| Armazenamento | TRIM, NTFS, cache de gravação |
| Privacidade e Debloat | Telemetria, relatórios de erro, Xbox, Bluetooth, impressão |
| Apps | Remover apps pré-instalados, Copilot |
| Rede | Nagle, DNS, TCP, placa Ethernet, IPv4/IPv6 |
| Extras | Extensões de arquivos, modo escuro, menu de contexto clássico |

O risco de cada ajuste é indicado por um ponto ao lado do nome: **amarelo** para médio e **vermelho** para alto. Os de alto risco nunca vêm marcados e pedem confirmação extra.

## Segurança e reversão

- **Ponto de restauração**: botões *Criar* e *Restaurar* na barra lateral. O Breath também oferece criar um antes de aplicar.
- **Reverter**: marque os ajustes e clique em *Reverter* para voltar exatamente ao estado anterior.
- Backup e log ficam em `C:\breath\`.

## Desenvolvimento

O código-fonte é o [`breath.ps1`](breath.ps1) (PowerShell + WPF). O `dist/breath.cmd` é gerado a partir dele, com o script embutido:

```
./build.sh
```

Rode o build depois de qualquer alteração no `breath.ps1`.

---

Criado por **samu-lls** · Licença [MIT](LICENSE).
