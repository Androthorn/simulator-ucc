# Pré-registro — ciclo controlado de refinamento (workshop UCC)

> **Status:** congelado em 2026-07-20, **antes** de qualquer run fresco.
> Nada aqui pode ser alterado depois de a fila começar. Alterações posteriores
> entram como *adendo datado*, nunca como edição — o valor deste documento é
> ele ter sido escrito primeiro.
>
> Contexto e histórico: `../ESTADO-workshop-hefesto.md` (raiz de `projetos/`, fora de repo). Este arquivo é só o que
> foi decidido antes de ver o dado.

---

## 1. A pergunta

O paper documenta um nulo: um loop de refinamento de prompt *parecia* melhorar
a estabilidade de um scheduler multi-agente, mas o experimento confirmatório
(n=30/braço) não achou efeito. A causa foi **avaliação de 1 run + promoção sem
teste**.

Este experimento não tenta ressuscitar o loop. Ele pergunta:

> Um gate de promoção estatisticamente correto separa sinal de ruído onde a
> regra antiga não separava — e ainda detecta um refinamento real quando existe?

São duas afirmações, medidas separadamente: um **controle nulo** (o gate recusa
o que não é ganho) e um **braço de tratamento** (o gate ainda enxerga o que é).

---

## 2. Desenho

Três braços, réplicas frescas, **ordem intercalada** `p0, p0', p1, p0, p0', p1, …`
para que qualquer deriva temporal do cluster atinja os três igualmente.

| braço | prompt | sha256[:8] | papel |
|---|---|---|---|
| `p0` | consolidator_agent_p0 (LF efetivo) | `8840d32d` | campeão |
| `p0'` | idêntico ao p0 | `8840d32d` | controle nulo |
| `p1` | p0 + 2 few-shots do p4 | `35c8905d` | tratamento |

**k = 12 réplicas por braço.** Total 36 simulações, ~13 min cada, ~$0,26 cada
⇒ **~8 h de parede, ~$9,7**. Saldo disponível na key: $16,17 (medido em 20/07).

### Construção do p1 — uma variável, verificada

`p1 = p0 + bloco "## Examples"` contendo **2** dos 3 few-shots do p4:
"Pending Pods vs. Cost Savings" e "Workload Already on Public".

O terceiro ("CPU Overload without Pending Pods") foi **omitido**: seu texto de
*Correct reasoning* afirma "CPU overloads are acceptable", que contradiz a regra
do p0 ("Performance/Capacity rules são hard constraints"). Colado verbatim, ele
importaria uma regra do p4 pela porta dos fundos e o contraste deixaria de ter
uma só variável.

Verificações feitas antes de congelar:
- Diff p0→p1 é **inserção pura** (`12a13,24`, zero linhas removidas ou alteradas).
- Remover o bloco do p1 reproduz `cand_8840d32d.txt` **byte a byte** — o artefato
  exato que gerou as réplicas do baseline.
- Todas as 12 linhas inseridas são **verbatim do p4**; zero texto autoral.

**Declarado:** o p1 é UTF-8 e o p0 é ASCII puro — o exemplo 3 do p4 contém um
travessão (—). Corrigir exigiria texto autoral, então fica declarado.

**Declarado:** o p0 em disco está em CRLF (sha `dd68a998`) mas **nunca rodou**;
`read_text()` normaliza por universal newlines, então o prompt entregue ao LLM é
a versão LF, sha `8840d32d` — o sha8 que nomeia toda réplica. O p1 foi construído
contra o artefato efetivo.

---

## 3. Tratamento de dados — critérios fixados antes do dado

Três modos de execução foram caracterizados nas réplicas de diagnóstico. O
critério é **contagem de migrações**, output direto da decisão do consolidator:

| modo | critério | ação |
|---|---|---|
| normal | `0 < migr ≤ 50` | mantém |
| **thrash** | **`migr > 50`** | exclui **só** na análise confirmatória (§4b) |
| **stall** | **`migr == 0`** | exclui **e reporta a contagem** — tripwire (§4d) |

**Por que 50:** o vão observado é 33 (maior normal) → 74.8 (menor thrash no A1)
→ 103.2 (thrash no comprimido). Qualquer corte em 40–70 separa igual; 50 é o meio
e é redondo. Fixado **antes** de olhar qualquer dado do p1.

**Por que o thrash pode ser excluído (e o §4d não podia):** o modo é nomeado e
caracterizado, não "ficou feio". Sua taxa é **invariante ao prompt** — 3/30 no p0
e 3/30 no p4 dos 80 runs congelados do TCC — então excluí-lo não favorece braço
nenhum. E o critério é numérico e pré-registrado. Isso é o oposto do descarte
post-hoc que o paper critica, e deve ser dito assim no writeup.

**Por que o stall é tripwire e não exclusão simples:** o bug do zero-ciclo foi
corrigido (`ai-engine@8b7b7e3`), mas apareceu nos runs de diagnóstico. Uma run
com zero migrações em dado fresco significa que **o fix não segurou neste
config** — é sinal, não sujeira. Protocolo: exclui do braço, reporta
"N runs stall descartadas", e **se N > 0, para e investiga antes de confiar na
fila**.

**Nenhuma outra exclusão.** Runs que falham no meio (exit≠0, CSV ausente) são
descartadas e re-enfileiradas inteiras — nunca aproveitadas parcialmente.

---

## 4. As três análises

Rotuladas por status. A distinção é o ponto: só a §4a sustenta a afirmação
central; as outras duas são declaradamente contingentes.

### 4a. PRIMÁRIA — taxa de falsa promoção (controle nulo)

**Dados:** as 24 réplicas nulas (`p0` + `p0'`), **mistura inteira, sem exclusão**.

**Método:** resampling não-paramétrico. Divide-se repetidamente as 24 em dois
braços disjuntos de 12 e aplica-se cada regra. Como ambos os braços vêm do mesmo
prompt, **toda promoção é falsa por construção**.

Três regras, sobre exatamente as mesmas divisões:

| regra | critério | o que é |
|---|---|---|
| `naive` | `mean_cand > mean_champ` | a do ADRS — o que o paper critica |
| `legacy` | `delta > ε·σ`, ε=1.0, pareado por zip | a do hefesto antigo |
| `gate` | `LB(cand−champ) > δ_min` | a nova (opção B) |

**Por que não excluir o thrash aqui:** o método é não-paramétrico e usa a
distribuição empírica. O thrash é **parte do que engana** as regras ingênuas —
excluí-lo destruiria o resultado.

**IC:** bootstrap sobre as **réplicas** (reamostra as 24 com reposição), não
sobre divisões. Divisões se sobrepõem e não são evidência independente. **O n a
reportar é 24 runs, nunca o número de divisões.**

**Predição registrada** (de gaussiano sintético com σ=0.0216, k=12): `naive` ≈ 50%,
`legacy` ≈ 0,4%, `gate` ≈ 0%. Se o dado real divergir muito disso, é achado, não erro.

**Nota que vai no paper:** o "~50%" documentado não é da regra ε·σ — é da regra
ingênua, que é o que `analysis/replay_gate.py` mede. As duas **coincidem em n=1**,
e o motivo é estrutural: com uma réplica só, o `pstdev` de um delta único é zero,
então `delta > ε·0` degenera em `delta > 0`. Como o ADRS avaliava com n=1, o ~50%
está certo *para o sistema como operado*. O defeito preciso da ε·σ não é ser
permissiva — é a taxa de erro ser função descontrolada de k (50% → 25% → 15% →
0,4% conforme k=1,2,3,12), sem alvo declarado, coincidindo com cara-ou-coroa
exatamente no n que o sistema usava.

### 4b. CONFIRMATÓRIA — média-S (tratamento)

**Dados:** `p1` vs `p0`, **thrash excluído** (migr > 50), stall excluído e reportado.

**Método:** o gate da opção B — promove sse `LB > δ_min`, Welch não-pareado.

**Parâmetros, fixados agora:** `k=12`, `δ_min=0.05`, `α=0.05` (unilateral).

**Efeito mínimo detectável:** com σ=0.0216 (n=9 do baseline limpo sob este mesmo
critério de exclusão), `SE = 0.0088`, o gate promove com `diff > 0.0651`, e um
efeito verdadeiro de **~0.073** passa com 80% de poder.

**Registrado explicitamente:**
- **O MDE é 0.073.** É o que este experimento promete detectar. Não "0.05".
- **Não haverá poder post-hoc.** Reporta-se a σ observada e o IC do efeito; poder
  calculado depois do resultado é o p-valor disfarçado.
- **k não será ajustado depois de ver o p1.** 12 está fixado, conservador, pronto.
- σ vem de n=9 (±25% de incerteza) e 8 dos 9 são pré-fix. Runs frescos devem ser
  mais limpos ⇒ 0.0216 é **teto conservador**; se a σ fresca for menor, o IC do
  efeito vem mais apertado de brinde.

**Reportar junto, descritivo:** a média-S da mistura completa (sem exclusão), para
que o efeito da exclusão seja visível e ninguém precise confiar na nossa palavra.

### 4c. EXPLORATÓRIA — taxa de thrash (tratamento)

**Dados:** `p1` vs `p0`, **completos, sem exclusão**.

**Método:** taxas observadas + IC. **Declaradamente subpotente** — evento de ~10%
com k=12 pede n≈50–80 por braço para ter poder de verdade.

**Por que existe mesmo assim:** os few-shots do p1 miram decisão de migração, então
"p1 reduz thrash?" é a hipótese mecanicamente motivada. E é a rede de segurança do
desenho: **se o p1 agir reduzindo a taxa de thrash, a confirmatória (que exclui
thrash) daria ~nada** e só esta análise pegaria o sinal.

Nenhuma afirmação confirmatória sai daqui. Se apontar algo, vira *future work*
com número, não conclusão.

---

## 5. O que cada desfecho significa

Registrado agora para que nenhum resultado possa ser reinterpretado depois.

| resultado | leitura |
|---|---|
| §4a mostra `gate` ≪ `naive` | **A contribuição central está entregue**, independente do tratamento. |
| §4b promove o p1 | O gate detecta refinamento real. Ganho reportado com IC. |
| §4b não promove | Nulo informativo: ou não há efeito ≥0.073, ou ele não está na média-S. Ver §4c. |
| §4c sugere queda de thrash | Hipótese para o próximo estudo, com estimativa de n. |
| stall aparece em dado fresco | **Para.** O fix não segurou; investigar antes de confiar na fila. |

O paper é publicável em qualquer linha desta tabela. Essa é a razão de o desenho
ter um controle nulo como análise primária, e não o tratamento.

---

## 6. Precondições antes da fila

1. **Smoke frescas** (2 réplicas, ~$0,52): verificar que a composição de modos
   bate (sem stall, headroom de pé) e que o config comprimido está entregando
   scheduler 90s / lookback 180s. **Não** re-estimam σ — n=2 é lixo para isso.
2. **Confirmar o saldo** na key imediatamente antes de enfileirar: ela é
   compartilhada (`usage_monthly` $26,28) e o plano consome ~60% do que resta.
3. **Nenhum push** dos commits locais sem o André pedir (§5 do ESTADO).

---

## 7. Proveniência

Por réplica, `provenance.json`: sha256 do prompt / config / input, modelo,
temperatura, commit git dos três repos. Runs que falharem são descartadas
inteiras e re-enfileiradas.

**Software congelado neste pré-registro:**

| componente | referência |
|---|---|
| gate (opção B) | `hefesto@697043f` — `hefesto/core/gate.py` |
| resampling | `hefesto@9928274` — `hefesto/core/resample.py` |
| regra antiga (comparação) | `legacy_epsilon_sigma_rule`, portada de `loop.py@3c8c001` |
| score S | `analysis/ucc_scoring.py` — fonte única, cross-check em teste |
| fix do zero-ciclo | `ai-engine@8b7b7e3` |
| prompts | `ai-engine@a657919` — p0/p4/p1 versionados com EOL protegido |

A t inversa do gate é implementação própria (sem scipy), fixada por teste contra
tabela publicada em 13 pontos. É deliberado: se o gate importasse scipy, a decisão
de promoção passaria a depender da versão de uma lib numérica e um upgrade poderia
mudar uma promoção em silêncio.

---

## Adendo 1 — decomposição de S por componente (2026-07-20)

> **Adendo, não edição.** Nada acima foi alterado. Escrito **depois** do smoke de 2
> réplicas (`runs-workshop/p0_smoke_prefila/`, ambas normais: migr 24, 5 ciclos, zero
> ciclos pulados) e **antes** de qualquer réplica dos três braços. Motivado por análise
> do mecanismo do tratamento, não por resultado — não existe dado de `p1`.

### O problema: os eixos do tratamento brigam dentro do S

Decompondo uma réplica de p0 do smoke (S=0.7574):

| componente | sub-score | peso | contribuição | teto p/ ganhar |
|---|---|---|---|---|
| `pending_pods` | 0.821 | 0.35 | 0.2873 | +0.0627 |
| `time_with_pending` | 0.784 | 0.25 | 0.1960 | +0.0540 |
| `cost` | 0.568 | 0.25 | 0.1420 | +0.1080 |
| `number_of_migrations` | 0.880 | 0.15 | 0.1320 | +0.0180 |
| **S** | | | **0.7574** | **+0.2426** |

Os dois few-shots do p1 ensinam *"pending é prioridade absoluta → migra pro público"* e
*"já está no público → não traz de volta"*. **Ambos empurram para mais colocação pública**,
o que melhora disponibilidade e piora custo:

- ganho possível em `pending` + `twp`: **até +0.110** (teto teórico dos dois somados)
- perda possível em `cost`: **até −0.141**

Para atingir o MDE de 0.073, o p1 precisaria capturar ~66% do teto de disponibilidade
**com penalidade de custo próxima de zero**. É um caminho estreito.

**A consequência:** se o teste do S agregado der ~zero, o desenho atual **não distingue**

- **(a)** o prompt não mudou comportamento nenhum, de
- **(b)** o prompt mudou comportamento e os pesos do score cancelaram os efeitos.

São achados diferentes, e **(b) é o mais forte** — é uma afirmação sobre a métrica do
próprio paper, não sobre o prompt. Neste desenho, é provável que o sinal de verdade
more na decomposição, não no agregado.

### O que fica registrado

**Análise confirmatória secundária (diagnóstica):** reporta-se a **decomposição de S nos
4 componentes** para `p0` e `p1` — sub-score médio por componente, com IC —, sob o mesmo
critério de exclusão da §4b (`migr > 50` fora, stall reportado).

**Predição direcional, registrada agora como hipótese:**
`pending_pods` ↑ · `time_with_pending` ↑ · `cost` ↓ · `number_of_migrations` ≈ ou ↓.

**Cláusula que mantém isto limpo:** **a promoção continua decidida SÓ pelo S agregado**,
pelo gate da §4b, com os mesmos k=12 / δ_min=0.05 / α=0.05. A decomposição é
**diagnóstica, nunca critério de promoção**.

Isso é deliberado e resolve duas coisas de uma vez:
1. **Multiplicidade:** 4 componentes **não** viram 4 testes de promoção. Há um teste de
   promoção, o mesmo de antes.
2. **Integridade do gate:** o critério pré-registrado não muda; nada aqui pode ser usado
   depois para justificar uma promoção que o S agregado recusou.

### O que este adendo NÃO faz

**Não reabre o endurecimento do workload** (Gate 1, decidido em 18/07: rodar assim). A
decomposição é justamente o que torna isso desnecessário — extrai-se resultado
interpretável mesmo com agregado nulo, sem mexer no cenário que já foi medido.

**Não muda k, δ_min, α, MDE, nem os critérios de exclusão.** Nada acima foi tocado.

---

## Adendo 2 — proveniência do runner e custo medido (2026-07-20)

> **Adendo aditivo.** Não altera nenhuma decisão de desenho: k, δ_min, α, MDE, critérios
> de exclusão e as três análises seguem exatamente como no corpo. Registra fatos que não
> existiam quando o §7 foi escrito. Escrito **antes** de qualquer réplica dos três braços.

### O runner entra na cadeia de proveniência

O §7 congela gate, resampling, score, fix e prompts — mas não o **runner**, porque quando
foi escrito ele vivia solto na raiz de `projetos/`, que não é repositório, e não tinha hash
para citar. O runner é o que decide qual prompt vai em qual réplica, em que ordem e com
qual modo de reset: sem ele, o pré-registro congela o desenho mas não o que executa o desenho.

| componente | referência |
|---|---|
| runner dos 3 braços | `simulatormeu@22fb776` — `run_experiment.py` |
| runners do gate 1 (baseline + smoke) | `simulatormeu@0ac6669` — `run_replicas.py`, `smoke_1_replica.py`, **sem alteração** |
| escalonamento (ordem + reset) | `hefesto@f807045` — `hefesto/core/schedule.py` |

Duas propriedades do escalonamento são fixadas por teste (`hefesto/tests/core/test_schedule.py`)
porque errar qualquer uma corromperia o experimento **sem erro visível**:

1. **Intercalação** `p0, p0', p1, p0, …` — deriva temporal do cluster atinge os três braços
   igualmente em vez de virar diferença entre eles.
2. **Reset balanceado** — o modo depende do índice *dentro* do braço, então cada braço recebe
   1 `full` + 11 `light`. Com o dispatch global anterior, só o primeiro run do conjunto seria
   `full` e um braço teria mistura diferente dos outros — confound enquanto a certificação
   `light ≡ full` não existir (segue pendente).
3. **Separação de diretório por braço** — `p0` e `p0'` são o mesmo prompt e portanto o mesmo
   sha8 (`8840d32d`). Derivar o destino só do hash faria os dois braços escreverem no mesmo
   lugar e destruiria o controle nulo em silêncio.

### Smoke pré-fila: passou

`runs-workshop/p0_smoke_prefila/`, 2 réplicas (1 `full`, 1 `light`), verificando o §6:

| | migr | ciclos | `CICLO PULADO` | inválidas | S |
|---|---|---|---|---|---|
| réplica 1 (`full`) | 24 | 5 | 0 | 0 | 0.7574 |
| réplica 2 (`light`) | 24 | 5 | 0 | 0 | 0.7550 |

Ambas normais pelo critério pré-registrado. **Tripwire limpo** — nenhum stall. Config viva
em scheduler 90s / lookback 180s. n=2 **não** re-estima σ e nenhuma conclusão é tirada disso.

### Custo medido, substituindo a estimativa

O saldo caiu de **$16,17 para $15,75** com 2 simulações ⇒ **$0,21/simulação**, abaixo dos
$0,26 de `analysis/CUSTO-experimento.md` (que vinha do cenário de 30 min). Projeção
atualizada para os 3 braços:

| | estimado ($0,26) | medido ($0,21) |
|---|---|---|
| 36 simulações | $9,36 | **~$7,6** |
| folga sobre $15,75 | $6,4 | **~$8,2** (~39 réplicas) |

O orçamento deixa de ser apertado. **Isso não muda k nem nada do desenho** — k=12 foi fixado
por poder estatístico, não por orçamento, e não será revisado.

---

## Adendo 3 — resultados e desvios (2026-07-21)

> **Escrito depois do dado.** É o primeiro adendo que vê resultado, e por isso não decide
> nada: todos os critérios estavam fixados em `5dcf2a7` / `beae8cb` / `f300d38`. Este
> registra o que se obteve e, com o mesmo peso, **o que não se sustentou**.
>
> Fila: 36/36 réplicas, zero falhas, tripwire limpo (nenhum `migr == 0`).
> `runs-workshop/experimento/`, 20/07 18:15 → 21/07 02:12.

### R1. Análise primária (§4a) — obtida, como registrada

24 réplicas nulas reais (`p0` + `p0'`), mistura inteira, sem exclusão, k=12:

| regra | taxa de falsa promoção | IC95 bootstrap | predito no §4a |
|---|---|---|---|
| `naive` (ADRS) | **50.7 %** | [45.0, 55.7] | ~50 % |
| `legacy` (ε·σ) | **0.4 %** | [0.0, 1.0] | ~0.4 % |
| `gate` (opção B) | **0.1 %** | [0.0, 0.3] | ~0 % |

*n reportável: 24 runs.* As três caem dentro do previsto. A predição veio de gaussiano
sintético com σ=0.0216; o dado real é mistura suja com σ bem maior e as taxas bateram
assim mesmo — que é a propriedade que se esperava de um método não-paramétrico, agora
verificada em vez de assumida.

### R2. Tratamento (§4b) — nulo nas duas versões

| | `p0'` vs `p0` (controle nulo) | `p1` vs `p0` (tratamento) |
|---|---|---|
| **com exclusão** (`migr > 50`) | +0.0139 (LB −0.0133) | +0.0164 (LB −0.0063) |
| **sem exclusão** (mistura inteira) | −0.0136 (LB −0.0610) | −0.0056 (LB −0.0500) |

Gate recusa os quatro. **O efeito do tratamento é indistinguível do que o controle nulo
produz do nada** — sem o braço `p0'` isto seria "+0.016, não significativo" com dúvida
permanente de poder; com ele, a resposta é positiva, não ausente.

Pós-exclusão: `p0` n=9 (0.6863 ± 0.0346) · `p0'` n=7 (0.7003 ± 0.0272) · `p1` n=7 (0.7027 ± 0.0136).
Sem exclusão: n=12 cada, 0.6576 / 0.6440 / 0.6519.

### R3. Decomposição (Adendo 1) — a predição direcional falhou, e o controle nulo explica

| componente | `p1` − `p0` | **`p0'` − `p0`** | predição do Adendo 1 |
|---|---|---|---|
| `pending_pods` | +0.0020 | **+0.0020** | ↑ |
| `time_with_pending` | +0.0408 | **+0.0407** | ↑ |
| `cost` | +0.0069 | −0.0021 | **↓ — falhou** |
| `number_of_migrations` | +0.0252 *(IC exclui 0)* | **+0.0237** | ~ |

Cada efeito do `p1` é replicado pelo controle nulo, **inclusive o único cujo IC exclui
zero**. Não é efeito de tratamento: é artefato de exclusão desigual — `p0` perdeu 3 runs,
`p0'` e `p1` perderam 5 cada, então os dois últimos sobram mais selecionados e parecem
melhores em tudo.

Sem o Adendo 1 e sem o braço `p0'`, `number_of_migrations` teria sido reportado como
efeito real do tratamento. **É o achado metodológico mais direto do experimento.**

### D1. Desvio — a premissa do critério de exclusão não se sustentou

O §3 justificou excluir `migr > 50` porque o modo era distinto, com vão largo, e sua taxa
era invariante ao prompt. Neste dado:

| | baseline (onde o critério foi calibrado) | este experimento |
|---|---|---|
| taxa de thrash | ~10 % | **36 %** (13/36) |
| vão bimodal | 33 → 103 (**70**) | 42 → 53 (**11**) |
| correlação S × `migr` | — | **r = −0.887** |
| excluídos por braço | — | **3 / 5 / 5** |

Com r=−0.887, excluir por migração aproxima-se de excluir por S (removidos: S médio 0.573;
mantidos: 0.696). Isso é **condicionar no desfecho** — precisamente o que o §3 argumentava
não estar fazendo, e o argumento dependia de uma bimodalidade que este dado não tem.

**Consequência declarada:** a §4a **sobrevive** — não usa exclusão e é não-paramétrica. A
§4b **não sobrevive como análise única**, e por isso vai reportada **nas duas versões**,
como o corpo já exigia. Nenhuma das duas versões muda a conclusão (nulo), o que limita o
dano; mas a limitação é da análise, não do resultado, e vai declarada assim.

### D2. Desvio — a calibração não transporta entre regimes

**σ=0.0216 e o corte em 50 foram derivados do baseline, e o baseline é outro regime.** O
MDE de 0.073 registrado no §4b herda essa calibração e deve ser lido como referente ao
regime em que foi medido, não a este. Nenhum número deste adendo foi usado para recalibrar
coisa alguma — k, δ_min e α ficaram como estavam, e não serão revisados retroativamente.

### O1. Observação — deslocamento de regime entre lotes

O mesmo `p0`, mesma config, mesmo modelo:

| | n | `migr` |
|---|---|---|
| `p0` histórico saudável (`p0_batch` 6 + `p0_clean` 3 + smoke 2) | 11 | **22 – 33** |
| `p0` nesta fila | 12 | **24 – 92** (média 46.5) |

Onze runs históricos nunca passaram de 33; aqui 3 de 12 passam de 50.

Duas explicações **descartadas** pelo próprio desenho:
- **não é deriva temporal** — por terço cronológico, `migr` médio 44.8 / 50.2 / 43.0, sem
  tendência (a intercalação existia para tornar isto verificável);
- **não é o prompt** — os três braços deslocaram igualmente (46.5 / 46.8 / 44.8).

**Hipótese em aberto, não fechada:** esta fila foi **92 % `light`** (33 de 36) enquanto o
baseline foi majoritariamente `full`. Os dois runs `full` sadios daqui deram `migr` 23.6 e
28.5, de volta à faixa histórica — mas são **n=3**, e sequências curtas de `light` deram
24–32 historicamente. **Isso não é evidência suficiente para acusar o `light`**, e este
adendo não o acusa. Registra-se o deslocamento como **observado** e a causa como
**desconhecida**.

⇒ **Próximo trabalho: a certificação `light ≡ full`**, pendente desde o §4d e agora com
motivo concreto e desenho óbvio (braços pareados de mesmo prompt, um por modo de reset).

### Leitura final

A **validade interna se mantém**: os três braços viveram o mesmo ambiente, na mesma ordem
intercalada, e a comparação entre eles é justa. O que não transporta é o calibre.

Nada foi re-rodado depois de ver o resultado, e nenhum critério foi ajustado
retroativamente — a fila foi executada uma vez, inteira, e é reportada inteira.
