---

I Built a Benchmark to Prove Tokens/Second Lies. Then My Own Rubric Lied to Me.

Eight local models benchmarked, four audited line by line, two machines, and the audit that reordered everything…twice.

**Provenance note:** I don't write code. The benchmark scripts were written by an LLM from my requirements, then run and debugged by me across many iterations until they produced clean data. I set the floors before testing, chose the environment policy, defined the tiers and cache rules, and decided when to stop a run. I ran everything and collected every row. The bandwidth math and the fabrication scan came from an LLM; I checked the quotes against the source myself and corrected two counts where my check and its scan disagreed. The implementation is the model's. The design and the accountability are mine.

---

There is a number that I almost let decide my whole stack. Seventy-three. As in seventy-three tokens per second, from a 4-billion-parameter model running locally on my oldest desktop — a GTX 1660 Super with 6 GB of VRAM. Fastest model in my fleet on that machine. Looked like the obvious winner. I nearly discarded the model that actually beat it.

Quick orientation, because this is the middle of a longer build: I'm self-taught, and I'm assembling a self-hosted AI stack on hardware I already own — always-on voice capture, chat, document processing, eventually agents. I'm at the step where I decide which model runs on which machine. These decisions cost real money, so I set acceptance floors before I test, and I don't get to move them afterward.

Here is the rule I forgot, in the moment, despite having written it myself: for agentic work, my floor is prefill, not decode. Prefill is how fast the model reads your prompt. Decode is how fast it talks. Different processes, bound by different hardware limits. Agents care about the first one.

So I went back to my own benchmarks.

| Context length | "Slower" model — prefill | "Faster" model — prefill |
| :---- | :---- | :---- |
| Short (\~60 tokens) | 213.6 tok/s | 168.6 tok/s — fails my 200 floor |
| Medium (\~535) | 258.9 tok/s | 251.4 tok/s |
| Long (\~4,300) | 257.4 tok/s | 247.8 tok/s |

The model I almost threw away wins at every single context length. The 73 tok/s model fails my agent floor outright on short prompts. It was never the strongest agent, just the fastest talker. I built this benchmark specifically to escape the tokens per second trap, then I fell right into it anyway, because 73 is a bigger number than 60 and bigger numbers feel like answers. That was the first trap. The second one, I built myself, and it took a fabrication audit to find it.

## What I Actually Measure, and Why

Decode is memory-bandwidth-bound: generating each token requires re-reading the model's active weights. Prefill is compute-bound: it processes your whole prompt in parallel batches. I've learned that one number cannot describe both. This is why I record four: time-to-first-token, prefill rate, decode rate, and end-to-end wall time. 

Then I gate on two floors that I declared before I started testing:

- **Conversational:** decode ≥ 15 tok/s. Below that, reading outpaces the model and chat feels broken.
- **Agentic:** prefill ≥ 200 tok/s, judged at the context length the agent actually uses. That second qualifier matters. Short prompts under-utilize GPU batching, so short-prompt prefill understates agent capability. One model in my fleet reads at 169 tok/s on a 60-token prompt and 251 tok/s on a 535-token prompt. Same model, same machine. If I had gated my decision on a short number, I would have rejected a model that clears my agent floor at every context length my agents actually use.

The protocol, and the one decision people argue with

Every performance run: output capped at 256 tokens, context pinned per tier, temperature 0, seed 42, a unique tag prepended to each prompt so the runner can't reuse cached work, one discarded warm-up, then five measured repetitions. Cold runs were recorded separately and never averaged into warm. I also leave my normal applications running. I'm not testing hypothetical single use devices, I'm benchmarking models that work on the hardware I have right now.

My oldest desktop is my always-on STT host. The API stays up, browser (Zen) stays open. I record free System Memory, flag any of the Top 15 processes over 500 MB and I don't kill a single one. A sterile machine is not the machine I use. If a model only fits when everything else is closed, then it doesn't fit. That decision produced possibly the most useful failure in my whole study.

## Finding 1: "cold" is two different states

In the first logged session, the 73 tok/s model's cold prefill read 3.3 tok/s against a warm 160.3 — a 48× jump. Time-to-first-token was 24,991 ms cold versus 449 ms warm.

Forty minutes later I ran the same model, same tier, same machine. Cold-after-unload prefill was 139.3 tok/s versus a warm median of 168.6 — only a 1.2× drop. But its time-to-first-token was 3.73 s cold versus 0.43 s warm: an 8.8× gap, almost all of it the 3.2 s model load.

Same model, same hour, two cold numbers 42× apart. Both accurate. Which means "cold" is not one state. There's cold-after-unload, where the weights reload but the kernels are already initialized, and first-use-after-driver-init, where something much more expensive happens once and then persists across reloads. Many of the published local benchmarks that I checked don't distinguish them. In fact, in the benchmarks I reviewed they don't mention warm-up at all.

Gate on TTFT alone and you'd call the model broken; gate on prefill alone and you'd miss the load cost entirely. That is why I record both. Both sessions are in the repo. I won't headline a number I can't reproduce.

## Finding 2: 32 GB of unified memory is NOT 32 GB of VRAM

Then I tried a 35B mixture-of-experts (MoE) that activates \~3B parameters per token. It should have been cheap. It decoded briefly in the same range at short context, but as the prompt grew it threw an HTTP 500 at 98% RAM, with commit charge reaching 41.9 GB on 32 GB of physical memory. It never finished the battery. Sparse activation doesn't help if all 35B of the weights have to sit somewhere.

LM Studio reports time-to-first-token and decode directly. Its prefill rate is prompt tokens ÷ TTFT, which underestimates the real rate — so a pass on that floor is safe and a fail needs re-checking. The long payload also tokenized differently per model, 4,254 to 4,461 tokens.

This is what reframed it for me. The math here came from an LLM, not from me: multiply decode rate by bytes read per token and you get implied effective memory bandwidth. Here's what I checked.

| Machine | Implied effective bandwidth | % of spec peak |
| :---- | :---- | :---- |
| Desktop, GTX 1660 Super (CUDA) | \~188 GB/s | 56% of 336 |
| Laptop, unified DDR5 (Vulkan) | 15.7–22.9 GB/s | 17–26% of \~89.6 |

The gap decomposes into two multiplicative factors: 3.75× peak bandwidth × \~2.6× efficiency ≈ 10×. The spec-sheet bandwidth difference is only part of the story — the Vulkan path also extracts about a fifth of theoretical bandwidth while CUDA extracts over half.

Here is what I can't separate. Every model on the laptop (Vulkan) is MoE. On the desktop (CUDA) I ran both dense and MoE — but the bandwidth figure above comes from the dense Qwen, because for a dense model the bytes read per token are essentially the whole file, so the estimate is clean. For the MoE Nemotron I only have the full file size, and multiplying by that would pretend every token reads all the experts, which overstates its bandwidth. So I left it out. That means my efficiency gap is dense-on-CUDA versus MoE-on-Vulkan, and I cannot attribute it to the backend alone — expert gathering is inherently less bandwidth-efficient than dense streaming. The experiment that separates them is one small dense model on the laptop. That is the next thing I'm running.

What I can say without hedging: unified memory bought me the ability to load a 24B model. It did not buy me the ability to talk to one. I read 32 GB and thought VRAM. That was my error.

## Finding 3: one model, two completely different verdicts

GPT-OSS-20B reads a 4300-token document at 208 tok/s which is above my agent floor. It generates at 7.8 tok/s, which is half my conversational floor. It is a good reader and a bad talker. A single tok/s reading would render that invisible, and would have led me to reject a model with agentic potential.

Then I looked at the token counts. On nearly every run it spent 253 of 256 output tokens thinking. Three tokens left for the answer. So that 7.8 tok/s measured its thinking, not its answering. I raised the cap to 1024 for the quality round and haven't read the answer-token count yet, so its quality score is marked budget-limited rather than a clean measure of what it can do.

## The second trap: a rubric that measured the wrong thing

For the quality test I used an excerpt from a recent Bridgewater newsletter and asked each model to extract the five most important financial metrics with their significance (I've learned that 'most important' is sloppy in and of itself, but that's why we iterate). Then, I built a five-anchor key from the source's own numbers. Three of four models failed. One passed 4 of 5\. I had my headline. Then, while I was auditing claims against the source I found that my key had a bug. I had required each anchor to appear as its own numbered item. But models bundle. One wrote: "Nvidia has overtaken Apple to become the most valuable company relative to GDP in history, with more compute built in the last two years than in the prior six combined. It indicates a shift where a handful of companies (like OpenAI and Anthropic) could control a third of global AI compute by 2028."

Three of my five anchors lived in one paragraph, and my key scored two of them as absent. I've re-scored as fact present anywhere:

| Model | Original | Re-scored |
| :---- | :---- | :---- |
| Qwen 3.5 4B | 4.0 | 4.67 |
| LFM 2.5 24B | 3.3 | 4.67 |
| Nemotron 4B | 2.7 | 3.00 |
| GPT-OSS 20B | 2.0 | 2.00 |

They tie. My "only one model passes" conclusion was now an artifact of my scoring convention. Bundling isn't a recall failure, it's a format failure. Which now meant that this needs three axes, not one: recall (did the fact appear), fidelity (was it stated correctly), format (five discrete items).

Collapsing those into a single pass/fail hid the actual result and also broke a claim that I'd been confidently making. I'd called the 4B model's omission deterministic. The same miss, every time, therefore engineerable. Under the corrected scoring, it's present in two of three runs — a different miss each time. The model with genuinely deterministic omission is the one I was ready to excuse. GPT-OSS skipped an entire paragraph, three anchors, in all three runs, without exception.

## What actually separated them

Not recall. Fidelity.

The source says AI equities discount \~3.5% productivity growth, and that this is more than needed for US debt sustainability. It never states a numeric threshold.

Two models invented one:  
**Nemotron:** "the economy only needs \~2.5% to manage debt" and then later, "The text compares the 3.5% AI productivity premium with the U.S. debt sustainability threshold (\~2.5%)."  

**GPT-OSS:** "exceeds the 2–2.5 % growth needed for debt sustainability in many advanced economies."  

Two unrelated models, from different labs, filled the same gap with the same made-up number. One said the document gave it to them.

All four models inverted the source's central comparison at least once in three runs. One said debt sustainability "requires more than 3.5%" which is backwards. Another called it a "discount rate" and glossed "discounting" as "undervaluing," which is not what the word means in finance. One response stated the comparison correctly in item 2 and inverted it in item 4 of the same response. And one model softened the source's language in every run: "increasingly beyond what they can absorb" became "nearing," "approaching," and "risk of exceeding." Numbers were correct but the urgency was quietly removed.

Fabrication invents facts, inversion flips relationships, and softening dampens tone. Here's the corrected tally, after I checked the scan against the source myself: **Qwen 3.5 4B** — zero fabrications, one inversion, two entity-count errors ("a handful of companies" where the source says two). **LFM 2.5 24B** — zero fabrications, one inversion, softening in all three runs. **Nemotron** — four fabrications, one inversion. **GPT-OSS** — an invented threshold, Canada grouped with the US and UK as at-limit when the source says Canada has room, an unfilled "\$X trillion" placeholder in all three runs, and two of three runs cut off mid-sentence.  

Earlier drafts of this piece said Qwen had two inversions and LFM had none. Both were wrong. These are the corrected counts.

For a financial readout, softening is the most dangerous failure mode in the set. Fabrication fails a check. Softening passes one and changes the meaning.

Final Tally: the 4B model and the 24B model both produced zero fabrications. The 4B Nemotron produced four. In recall they were equal; fidelity and hardware fit broke the tie.

## The finding I didn't expect

I came in believing that small models that iterate beat large models that can't. Parameter count predicted nothing about trustworthiness. A 4B model tied a 24B model on recall in my testing. Both had zero fabrications. While another 4B model (Nemotron) was the worst fabricator in the fleet.

What predicted usability was three things: does it fit my bandwidth, does it fail predictably, and can I afford to verify and re-prompt it. Size correlates with the first and third but it's irrelevant to trust.

## What I haven't done

In my experience, the gaps are the roadmap. Three runs means one miss moves the score 33 points. That's not enough to rank anything close. One person scored it, knowing which model wrote what, and I changed the convention after seeing the outputs. Nobody checked my scoring. The source document is public and widely discussed, so I cannot yet distinguish extraction from memorization. The control for that is to perturb a number in the source and see which value comes back. I haven't run it. I never asked them the same question without the article, so I don't know how much they already knew. The dense-vs-MoE debate is open. My efficiency figures rest on estimated active-byte counts, not measured bandwidth. Then there's my central thesis, that iteration rescues a small model and that is yet untested, because every run so far was a single-pass.

I'm building and contributing in public. The proper version locks the scoring rules before anyone reads an output, puts a second person on it blind, and checks whether the model already had the document memorized. I'm not there. This is round one, published with its holes named.

What would change my mind: a small dense model on the laptop landing near CUDA efficiency. That would move the 10× off the backend and onto expert gathering.

## Where this leaves me

What I'd tell someone choosing a model: Choose the model you can run for the task you need it to do, then set your floors before you test. Check what your rubric is actually measuring. Mine measured agreement with my formatting expectations. I only found that because I re-read the source against my own key.

This post is a single step in a longer build. I'm assembling a stack where my data stays mine, self-hosted by default, cloud by choice. I'm doing everything from voice capture to agents, on machines I already own. The spine I'm engineering against is Prompt → Context → Harness → Loop, and this post was a Harness decision: which model earns a place on which machine. The full map of the build is \[here\].

Next I test my own thesis — whether iteration rescues a small model — with a changed number in the source to check for memorization, and a second person scoring blind. Then model selection for reasoning, agentic workflows, OCR, embedding, and reranking, each with its own rubric.

The scripts, raw CSVs, scoring key, and fabrication audit are in the repo. The README says plainly that I don't write code — an LLM wrote these from my requirements and I ran and iterated them until the data was clean. Published as-run, not maintained. I can answer questions about the protocol and the floors. I probably can't answer questions about PowerShell. Fork it.

---

Appendix A: Claim-Evidence Audit

| Claim | Scope Tag | Evidence Source |
| :---- | :---- | :---- |
| Qwen 4B beats Nemotron on prefill at all three tiers | Observed | \`20261119-074453-M1\` |
| Two cold states differ 42× on the same model in the same hour | Observed | \`20261119-070651-M1\` \+ \`20261119-074453-M1\` |
| Cold-after-unload TTFT gap is 8.8×, mostly model load | Observed | \`20261119-074453-M1\` |
| Qwen 35B failed at 41.9 GB commit on 32 GB physical | Observed | \`20261119-122838-M2-LMS\` |
| GPT-OSS spent 253 of 256 output tokens thinking | Observed | \`20261119-122838-M2-LMS\` |
| Four laptop models cluster in a 7 GB/s band | Observed | Measured decode × estimated bytes per token |
| The 10× gap is bandwidth × efficiency | Interpreted | LLM-derived math; dense-vs-MoE not separated |
| Two models invented the same numeric threshold | Observed | \`testing\_battery\_1\_FAB.md\`, verbatim |
| All four inverted the central comparison at least once | Observed | \`testing\_battery\_1\_FAB.md\`, verbatim |
| Recall tied at 4.67 after re-scoring | Observed | Presence-anywhere convention, both scorings reported |
| Parameter count doesn't predict trustworthiness | Interpreted | Four models, two size classes |
| Iteration rescues a small model | Hypothesis | Untested |

Appendix B: Disclosure Log

**Scripts:** written by an LLM from my requirements, debugged by me across many iterations. Floors, environment policy, tiers, cache rules, and stop decisions were mine.

**Bandwidth math:** LLM-derived. I verified the dense model's file size against \`ollama ps\` and excluded the MoE figure because full-file bytes would overstate it.

**Fabrication scan:** LLM-assisted. I read every flagged quote against the source. Two counts corrected — Qwen inversions 2→1, LFM inversions 0→1.

**Re-scoring:** convention changed after seeing outputs. Both scorings reported. Not pre-registered.

**Cold-start claim:** promoted from hypothesis to observed after locating session \`20261119-070651-M1\`.

**Nemotron architecture:** confirmed sparse MoE from the model card.

**Voice:** drafted with an LLM against a written voice spec, revised by me. The accountability is mine.