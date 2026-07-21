# Prompts do experimento — cópias para proveniência

**Não editar. Não usar em execução.** Os arquivos que a infra lê continuam sendo os do
submódulo `ai-engine/prompts/`. Estes são **cópias byte-idênticas**, versionadas aqui
porque o submódulo aponta para `cloud-ai-ufcg/ai-engine` (repo de organização) e os
commits que versionaram os prompts existem apenas localmente — o que deixaria o
`PRE-REGISTRO-workshop.md` citando um hash que ninguém de fora consegue resolver.

Identidade provável por hash:

| arquivo | sha256[:16] | o que é |
|---|---|---|
| `cand_8840d32d.txt` | `8840d32d362ee1ef` | **o p0 que de fato rodou** — LF |
| `consolidator_agent_p0.txt` | `dd68a9989439e79f` | p0 como está em disco — **CRLF, nunca rodou** |
| `consolidator_agent_p1.txt` | `35c8905da31e74c3` | tratamento: p0 efetivo + 2 few-shots do p4 |
| `consolidator_agent_p4.txt` | `e46c69aa5b343752` | campeão do loop antigo (origem dos few-shots) |

O `8840d32d` é o sha8 que nomeia toda réplica (`r_8840d32d_*`): `read_text()` normaliza
terminadores por universal newlines, então o arquivo CRLF em disco nunca chegou ao LLM.
Os dois estão aqui porque os dois importam — um é a fonte, o outro é o que executou.

`.gitattributes` marca `prompts-experimento/*.txt -text` para o git nunca converter EOL:
sem isso, um checkout normalizaria o p0 de CRLF para LF e mudaria os bytes de um artefato
cujo hash é a identidade do experimento.

Para conferir que as cópias seguem idênticas ao submódulo:

```sh
cd simulatormeu
for f in consolidator_agent_p0.txt consolidator_agent_p4.txt; do
  cmp "ai-engine/prompts/$f" "prompts-experimento/$f" && echo "$f ok"
done
for f in consolidator_agent_p1.txt cand_8840d32d.txt; do
  cmp "ai-engine/prompts/workshop/$f" "prompts-experimento/$f" && echo "$f ok"
done
```

Origem no submódulo: `ai-engine@a657919` (local; ver `PRE-REGISTRO-workshop.md` Adendo 4).
