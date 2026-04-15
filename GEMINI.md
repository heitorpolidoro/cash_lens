# CashLens - Diretrizes de Engenharia

Este arquivo contém decisões arquiteturais e insights estratégicos para o desenvolvimento do projeto.

## Insights Estratégicos (Março 2026)

- **Arquitetura**: Priorizar PostgreSQL e descartar a ideia de MongoDB citada no TODO (o sistema já é fortemente relacional).
- **Performance**: O modelo de 'saldos encadeados' no Accounting é um risco de gargalo futuro; monitorar e planejar snapshots.
- **Escalabilidade**: O sistema é single-user; planejar Multi-tenancy/Auth se o objetivo for SaaS.
- **Robustez**: Migrar parsers de PDF (regex/pdftotext) para ML/LLM (Ollama) conforme sugerido no Roadmap.

## Roadmap de Curto Prazo Sugerido
- Refatorar `TransactionLive.Index` em componentes menores.
- Implementar parser OFX.
- Iniciar integração com serviço de ML para categorização.
