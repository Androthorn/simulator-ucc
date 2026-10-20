# Plano de Execução — Upgrade do paper pra UCC 2026 (main track)

> Documento de trabalho pro Claude Code. Contexto: paper "Searching for Stability" (SBC, `artigo-sbc.pdf`)
> vai pro main track da UCC 2026 (IEEE/ACM, Floripa, deadline **19/08/2026**). O upgrade = rigor
> estatístico na claim central + teste de transferência. Decisões abaixo já foram tomadas — não rediscutir.

## 1. Decisões fixas (13/07/2026)

- **Duração da run: 30 minutos, input original intacto.** Sem compressão pra 5min (morreu junto com o piloto).
- **Modelos: os mesmos do paper**, via OpenRouter (key antiga, com créditos): `google/gemini-2.5-flash` e `anthropic/claude-haiku-4.5`. Temperatura **0,1**.
- **Código-base dos experimentos: `simulatormeu/`** (clone da época do paper) — NÃO usar o `simulator/` novo (drifted: timeouts, defaults e prompts mudaram). Comparabilidade > novidade.
- **Re-rodar tudo fresco na mesma janela de dias.** Não misturar com dados de fev/mar (drift de provedor). Runs das condições comparadas devem ser INTERCALADAS.
- **Hefesto novo NÃO participa do experimento principal** (ver §7).

## 2. O que rodar — e o que NÃO rodar

**NÃO é tudo.** A Fase 1 do paper (3 modelos × 2 temps × 10 runs) fica como está — é descritiva
(seleção de modelo), o paper já a rotula como indicativa. O que se re-roda é só o que sustenta a
claim central e o resultado novo:

| Bloco | Config | Runs | Propósito |
|---|---|---|---|
| A1 | gemini-2.5-flash, T=0,1, prompt **p0** | 30 | baseline fresco da claim central |
| A2 | gemini-2.5-flash, T=0,1, prompt **p4** | 30 | claim central (0,739 vira resultado testado) |
| B1 | claude-haiku-4.5, T=0,1, prompt **p0** | 10 | baseline do teste de transferência |
| B2 | claude-haiku-4.5, T=0,1, prompt **p4** | 10 | **resultado NOVO**: p4 transfere pro modelo mais instável? |

**Total: 80 runs × 30min ≈ 40h de parede** (~5-7 noites, máquina do André, sem supervisão).
Ordem de execução: intercalar A1/A2 (p0, p4, p0, p4...) e B1/B2 idem. Se A terminar antes, B pode
começar — mas nunca rodar A1 inteiro num dia e A2 inteiro no outro.

**Nota pro texto do paper:** se o p0 fresco divergir do 0,695 da Fase 1 (drift), tratar como
"re-baselined at experiment time" na Fase 2 — a Fase 1 permanece como fase histórica de seleção.

## 3. Onde mexer — arquivos e repositórios

```
simulatormeu/                        ← base dos experimentos (época do paper)
  run_repeated_simulations.sh        ← script de fila JÁ EXISTE; precisa dos ajustes do §5
  run_multi_model_comparison.sh      ← referência de como trocar modelo
  simulator/data/config.yaml         ← config canônica: 10 nós, scheduler 300s, graph v2,
                                        input_const.json, gemini-2.5-flash, T=0,1
  simulator/data/input_const.json    ← workload do paper (81 deployments, ~30min) — NÃO TOCAR
  ai-engine/prompts/                 ← onde os prompts ativos vivem
  analyzer/                          ← gera combined_summaries.csv (entrada do score S)

paper-prompts/                       ← p0–p4 resgatados dos adrs.db (13/07)
  p0_baseline.txt · p1..p3 · p4_VENCEDOR_score0.7392.txt

hefesto/ (novo)                      ← NÃO usar no experimento principal; só no stretch (§7)
  git show dd2011e:compute_stability_scores.py  ← fórmula do S (pesos/baselines) — portar pro §6
```

## 4. Prompts — adequação e verificação (ANTES de qualquer run)

1. Criar `ai-engine/prompts/consolidator_agent_p0.txt` e `consolidator_agent_p4.txt` a partir de
   `paper-prompts/`. O formato esperado é system-prompt puro em txt (igual ao
   `consolidator_agent.txt` atual). Rodar `ai-engine/test_prompt_loading.py` pra validar o load.
2. **Verificação de fidelidade:** byte-compare `p0_baseline.txt` contra o `consolidator_agent.txt`
   do simulatormeu (devem ser idênticos). Conferir que o p4 contém os 3 exemplos few-shot descritos
   no paper (Pending vs Cost / CPU Overload / Already on Public).
3. A troca de prompt por run é feita apontando `consolidator_prompt_file` no config — **nunca**
   editando o txt ativo na mão (foi assim que se perdeu um lote de 10 runs em fevereiro, cf.
   FINDINGS.md do hefesto antigo).

## 5. Execução — ajustes no script de fila (o grosso do trabalho do Claude Code)

Modificar `run_repeated_simulations.sh` (ou criar `run_ucc_experiment.sh` que o envolva) com:

1. **Matriz de runs** (§2) com intercalação embutida — o script decide a próxima run pela paridade,
   não o operador.
2. **Log de proveniência por run** (o guardrail nº1): no diretório de output de cada run, gravar
   `provenance.json` com: timestamp ISO, modelo, temperatura, `sha256` do prompt ativo, `sha256` do
   config.yaml, `sha256` do input_const.json, git commit do simulatormeu. Isso torna o acidente de
   fevereiro impossível e vira material de reprodutibilidade pro paper.
3. **Nomenclatura de output:** `runs/{bloco}/{modelo}_{prompt}_{T}_run{NN}/` — o analyzer e o
   script de estatística leem daí.
4. **Resiliência:** retry com backoff pra falha de API; run que falhar no meio é descartada e
   re-enfileirada (não reaproveitar parcial); teardown/setup limpo do ambiente KWOK entre runs.
5. **Smoke test antes da fila:** 1 run completa de p0 + 1 de p4, verificar que o
   combined_summaries.csv sai, que o S calcula, e que o provenance.json registra o prompt certo.
   Só então soltar a fila noturna.

## 6. Estatística e figuras (depois dos dados; script novo `analysis/ucc_stats.py`)

Portar a fórmula do S de `git show dd2011e:compute_stability_scores.py` (pesos 0,35/0,25/0,25/0,15;
baselines 100/1,0/0,0776/200; C_fixed=0,0224) e produzir:

1. **Comparação de médias** p0 vs p4 (gemini): Welch t-test + Mann-Whitney U + IC 95% bootstrap
   (10k resamples) + Cohen's d.
2. **Comparação de variâncias** (A MANCHETE do paper é compressão de variância): teste de **Levene**
   + razão de desvios com IC bootstrap.
3. **Transferência** (haiku): mesmos testes, n=10 — reportar como exploratório.
4. **Saídas:** tabela LaTeX pronta (molde no compute_stability_scores.py antigo) + figuras 5 e 6
   refeitas com n=30 + boxplot p0 vs p4.

## 7. Hefesto novo — papel neste ciclo

**Fora do experimento principal.** O Hefesto novo não tem grader de métricas reais (só llm_judge)
e roda 1 chamada por caso — não reproduz o loop do paper sem implementação nova (WASPRunner +
StabilityGrader nas seams Runner/Grader).

**Stretch goal (só se o gate de 04/08 estiver verde e sobrar semana):** implementar o grader
`real_metrics` no Hefesto novo e rodar uma 2ª trajetória curta de refinamento (2 loops × 10 runs a
partir de p0, refinador = modelo de alta capacidade) pra atacar a limitação "single non-replicated
trajectory". Se não der: limitação permanece declarada, como já está no paper. **Não começar por
isso em hipótese alguma — é a cereja, não o bolo.**

## 8. Escrita (28/07 em diante, manhãs)

1. Converter SBC → template IEEE conference (conferir formato exato no CFP: ucc2026.ufsc.br).
2. Des-anonimizar conforme regra da UCC (conferir se é double-blind no CFP!).
3. Reescrever §5.2 com n=30 + testes; adicionar subseção de transferência (resultado novo).
4. Intro: 1 parágrafo de ênfase cloud-first (confiabilidade de operações autônomas de nuvem);
   related work já está bem apontado (AIOps).
5. Limitações: atualizar o que foi resolvido (significância) e o que permanece (trajetória única,
   um cenário, modelos de fev/2026 — justificar: consistência com a Fase 1).

## 9. Cronograma e gates

| Quando | O quê |
|---|---|
| 14–16/07 | §4 (prompts) + §5 (script) + smoke test — Claude Code |
| 16–23/07 | fila noturna dos blocos A e B (semana do SEAVER/festa — roda sozinha) |
| 24–27/07 | §6 estatística + figuras |
| 28/07–03/08 | escrita §8 (manhãs; PLN 03/08 e ATAL 04/08 têm prioridade nos conflitos) |
| **04/08** | **GATE:** dados + testes prontos e texto andando → main track. Senão → workshop (set) |
| até 15/08 | texto completo, revisão do Gio |
| **19/08** | **submissão EasyChair** (não deixar pro dia) |

## 10. Anexos — mapa completo de arquivos pro agente

Tudo abaixo está dentro da pasta do projeto (Tryout), caminhos relativos à raiz:

**Documentos de referência (ler primeiro):**
- `artigo-sbc.pdf` — o paper completo (metodologia §4, fórmula do S §4.2, resultados §5, limitações §6). É a fonte de verdade do que se está reproduzindo/fortalecendo.
- `PLANO-UCC-experimentos.md` — este documento.
- `Universidade.md` (seção "TCC — Paper WASP MAS") — histórico de decisões estratégicas.

**Repositórios:**
- `simulatormeu/` — **BASE DOS EXPERIMENTOS** (clone da época do paper, commit `05aa23b`). Contém: `run_repeated_simulations.sh` e `run_multi_model_comparison.sh` (fila), `simulator/data/config.yaml` (config canônica), `simulator/data/input_const.json` (workload do paper — read-only), `simulator/data/input_artigo.json` e `input_varia.json` (variantes, conferir uso), `ai-engine/prompts/` (prompts ativos), `ai-engine/test_prompt_loading.py` (validador), `analyzer/` (gera combined_summaries.csv), `scripts/` (setup KWOK/Karmada/Prometheus).
- `simulator/` — versão ATUAL do WASP. **Não usar nos experimentos** (drift). Útil só como referência de correções recentes se algo quebrar.
- `hefesto/` — Hefesto novo (generalista). Fora do caminho crítico (§7). O harness da época do paper está na história git: `git -C hefesto show dd2011e:compute_stability_scores.py` (fórmula do S + molde LaTeX) e `git -C hefesto show dd2011e:FINDINGS.md` (histórico dos loops, incl. o acidente de config).

**Dados e prompts:**
- `paper-prompts/p0_baseline.txt` ... `p4_VENCEDOR_score0.7392.txt` — a linhagem completa de prompts do consolidador (resgatada 13/07 dos bancos abaixo). p0 e p4 são os que entram na matriz do §2.
- `paper-prompts/adrs.db` e `paper-prompts/adrs_history.db` — bancos SQLite do ADRS da época: tabelas `prompts`, `evaluations` (scores por iteração), `refinements` (reasoning de cada refinamento). Fonte primária se algum prompt precisar de re-verificação; útil também pro stretch goal (§7).

**Credenciais (não estão no repo):** key do OpenRouter da época — pedir ao André; vai em `.env` do ai-engine (`OPENROUTER_API_KEY`). Estimar custo no smoke test antes da fila (§10-riscos).

## 11. Riscos e respostas prontas

- **Modelo sumir do OpenRouter no meio da janela** → por isso a janela é curta e intercalada;
  se acontecer, o bloco afetado reinicia inteiro com substituto documentado.
- **Créditos da key acabarem** → estimar custo no smoke test (tokens × 80 runs) e avisar André
  ANTES de soltar a fila.
- **p0 fresco muito diferente do histórico** → não é falha, é drift: reportar re-baseline (§2).
- **Fila travar de madrugada** → provenance + nomenclatura permitem retomar do ponto exato;
  o script deve ser idempotente (runs completas são puladas).
