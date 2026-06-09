# Importação em lote por pasta (`.account` routing)

**Data:** 2026-06-08
**Status:** Aprovado para implementação

## Problema

Hoje a importação de extratos é feita pelo modal LiveView (`ImportModalComponent`):
o usuário seleciona **uma** conta de destino e faz upload dos arquivos, que são
todos parseados com o `parser_type` daquela conta. Para importar extratos de
várias contas, o processo precisa ser repetido manualmente para cada uma.

O usuário organiza os downloads em pastas — **cada pasta corresponde a uma conta**.
Quer poder apontar para uma pasta-pai e importar tudo de uma vez, com o sistema
roteando cada arquivo para o parser correto da conta certa.

Complicação: existem **duas contas chamadas "Conta Corrente"** (Bradesco e Banco
do Brasil), então o nome sozinho não identifica a conta de forma única.

## Solução

Um arquivo `.account` em cada pasta declara a qual conta aquela pasta pertence.
A lógica de roteamento vive em um módulo reutilizável (`CashLens.Parsers.DirectoryImporter`)
e é exposta primeiro via mix task. A UI web futura consome o mesmo módulo.

### Abordagem

- **Recomendada (escolhida):** módulo reutilizável + mix task fina por cima.
  A UI futura chama `DirectoryImporter.run/2` diretamente, sem duplicar lógica.
- Descartada: lógica inteira dentro da mix task (não reaproveitável na UI).

## Componentes

### 1. Arquivo `.account`

Formato `chave: valor`, uma chave por linha:

```
bank: Banco do Brasil
account: Conta Corrente
```

Regras de parsing:

- Duas chaves obrigatórias: `bank` e `account`. Ordem livre.
- `trim` em chave e valor; comparação **case-insensitive**.
- Linhas em branco e linhas iniciando com `#` são ignoradas (comentários).
- Faltando `bank` ou `account` → erro naquela pasta (mensagem clara), segue as demais.

Resolução do par `(bank, account)` contra a tabela `accounts`:

- **0 contas** casadas → erro `"conta não encontrada"`.
- **2+ contas** casadas → erro `"ambíguo: qualifique"`.
- **1 conta** casada → importa.

### 2. `CashLens.Parsers.DirectoryImporter`

API principal:

```elixir
@spec run(path :: String.t(), opts :: keyword()) :: %DirectoryImporter.Result{}
```

Retorna uma struct com resultados estruturados (sucessos por conta, warnings,
erros) — a mix task formata para o terminal; a UI consome o mesmo struct.

### 3. Mix task `Mix.Tasks.CashLens.Import`

```
mix cash_lens.import <caminho>
```

Inicia a app (`Mix.Task.run("app.start")`), chama `DirectoryImporter.run/2`,
imprime o relatório e sai com status != 0 se houver erros.

## Fluxo de dados

### Varredura (recursiva)

1. Percorre as subpastas de `<caminho>`.
2. Para cada subpasta **com `.account`**: resolve a conta e importa os arquivos
   suportados daquela pasta naquela conta.
3. Subpasta **sem `.account`** → **warning**, pula (não é erro fatal).
4. Se o próprio `<caminho>` tiver `.account`, ele também é tratado como uma conta
   (cobre apontar direto para uma pasta de conta única).

### Guarda de formato

Cada `parser_type` espera um formato de arquivo:

| parser_type     | extensão esperada |
|-----------------|-------------------|
| `bradesco_csv`  | `.csv`            |
| `bb_csv`        | `.csv`            |
| `ourocard_ofx`  | `.ofx`            |
| `standard_ofx`  | `.ofx`            |
| `sem_parar_pdf` | `.pdf`            |

Apenas arquivos cuja extensão bate com o parser da conta são enviados ao parser.
Extensões divergentes na pasta viram **warning** e são ignoradas (evita alimentar
um OFX num parser CSV, por exemplo). Reaproveita / estende `Ingestor` —
`import_file/3` já existe e é chamado por arquivo.

### Disposição dos arquivos

Os arquivos **permanecem no lugar** — não são movidos nem apagados. A dedupe por
`fingerprint` já existente torna re-execuções seguras: ao rodar de novo após
"atualizar os extratos", duplicatas são puladas (`skipped`). Sem pasta de
"processados".

### Pós-processamento

- Detecção de parcelas roda **uma vez ao final** de toda a importação
  (`CashLens.Installments.scan_and_apply_all()`), igual ao fluxo da UI — parcelas
  de uma compra podem cruzar vários extratos mensais.
- Recálculo de saldos por período já é disparado pelo `Ingestor` a cada
  `import_file`.

## Tratamento de erros

- Erro em uma pasta (conta não encontrada, ambígua, `.account` malformado) **não
  interrompe** as demais — é coletado no relatório.
- Falha de parsing de um arquivo é reportada sem derrubar a pasta inteira.
- A mix task sai com código != 0 se houver qualquer erro (para uso em scripts).

## Relatório (saída no terminal)

```
✓ Banco do Brasil / Conta Corrente   142 importadas, 8 já existiam
✓ Bradesco / Conta Corrente           67 importadas
⚠ pasta "fatura-antiga/" sem .account — pulada
✗ pasta "cripto/" — conta 'X' não encontrada
```

## Testes

- `.account` resolvendo corretamente; par ambíguo; par inexistente; arquivo
  malformado (chave faltando, comentários, linhas em branco).
- Pasta sem `.account` → warning, não quebra as outras.
- Guarda de extensão filtrando arquivo de formato errado (warning).
- Recursão pegando múltiplas contas numa única rodada.
- Idempotência: rodar 2x → segunda execução só `skipped`, sem duplicatas.

## Fora de escopo (YAGNI)

- Feature na UI web (fica para uma iteração seguinte; o módulo já fica pronto para reúso).
- Mover/arquivar arquivos processados.
- Auto-detecção de parser por conteúdo (o `.account` + `parser_type` da conta resolve).
