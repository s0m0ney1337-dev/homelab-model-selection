# Homelab Model Selection, Round 1

I set my acceptance floors before testing. Then I broke one anyway. My own rubric scored a real failure as a pass, and I only found it because I audited the scoring against the source.

This repo is the record of that. Not a benchmark of these models on the whole — a record of how I chose which models run on which machine for a self-hosted stack, on hardware I already own, with the parts I got wrong left in.

## What this is

A decision-quality case study, not a benchmark paper.

The stack is always-on voice capture, chat, document processing, eventually agents. The decision is which model runs where. I set floors before testing, kept the real environment (apps running, STT host up), logged provenance for every number, audited my own scoring, found it was wrong, and changed the conclusion. The benchmark is the vehicle. The point is how to make a technical decision with incomplete data and know how defensible it is.

## What this is not

- **Not a ranking of these models.** It's how they fit my use case, on my hardware, under my environment policy.
- **Not reproducible research.** Three runs, one scorer who knew which model wrote what, no blind second reviewer. The gaps are named below.
- **Not maintained.** The scripts were written by an LLM from my requirements, run and debugged by me across many iterations until the data was clean. Published as-run. I can answer questions about the protocol and the floors. I probably can't answer questions about PowerShell.

## What's in here

| Path | What it is |
|---|---|
| `essay.md` | The full write-up. Start here. |
| `scripts/bench_m1.ps1` | Ollama runner — M1 (GTX 1660 Super, CUDA), dense and MoE. |
| `scripts/bench_m2.ps1` | LM Studio runner — M2 (unified memory, Vulkan), MoE. |
| `scripts/bench_realdoc.ps1` | Real-document extraction runner — the quality and fabrication half. |
| `data/runs_m1_070651.csv` | M1 first-logged session. Source of the 48× cold-prefill jump. |
| `data/runs_m1_074453.csv` | M1 main performance session. Four models × three tiers × warm reps plus cold. |
| `data/runs_m2_122838.csv` | M2 performance runs, complete. Four MoE models × three tiers × warm reps plus cold, including the 35B failure (two HTTP 500 rows) and the GPT-OSS reasoning-token counts. |
| `data/bench_long.txt` | The canonical long prompt, shared by both machines. |
| `data/realdoc_article.md` | The source article used for the quality and fabrication test. |
| `data/bench_realdoc.md` | The realdoc prompt wrapper, applied identically to every model. |
| `data/20261119-162529-M1-RD/` | M1 realdoc session: Qwen and Nemotron answers (3 reps each), `realdoc_runs.csv`. |
| `data/20261119-173846-M2-RD/` | M2 realdoc session: LFM and GPT-OSS answers (3 reps each), `realdoc_runs.csv`, `baseline.txt`. |
| `audits/SCOREKEY_realdoc.md` | The five-anchor scoring key, per-model per-anchor pass/fail. |
| `audits/testing_battery_1_FAB.md` | The source article, all four models' verbatim responses, and the fabrication audit. |

## What's not here

Named on purpose. The gaps are the roadmap.

- **The complete M2 performance CSV.** `data/runs_m2_122838.csv` truncates partway through the gemma rows. The GPT-OSS-20B and 35B MoE runs cited in the essay are not in that file. The GPT-OSS fabrication evidence survives separately in `data/20261119-173846-M2-RD/`; the 35B failure (`20261119-122838-M2-LMS`) is the only claim without a receipt on disk.
- **A second scorer.** One person scored it, knowing which model wrote what. The proper version puts a second person on it blind. Not done.
- **A memorization control.** The source article is public and widely discussed. The check is to perturb a number in the source and see which value comes back. Not run.
- **A dense-vs-MoE control.** My efficiency figures rest on estimated active-byte counts, not measured bandwidth. One small dense model on the laptop would separate the backend effect from the expert-gathering effect.

## Why I stopped

I got the answers I needed for round one, and I don't like testing. More testing of the same thing wouldn't change the decision.

Round two asks a different question: whether iteration rescues a small model. That run needs a changed number in the source and a second scorer blind to which model wrote what. Neither exists yet.

## Provenance

The design and accountability are mine. I set the floors before testing, chose the environment policy, defined the tiers and cache rules, ran everything, collected every row, and decided when to stop. The implementation is an LLM's: scripts, bandwidth math, fabrication scan. I checked every flagged quote against the source myself and corrected two counts where the scan and my check disagreed. Full disclosure in Appendix B of the essay.

## What would change my mind

A small dense model on the laptop landing near CUDA efficiency. That would move the 10× gap off the backend and onto expert gathering, and the dense-vs-MoE question would open back up.

The essay's central claim — that iteration rescues a small model — is untested. Every run so far was single-pass. If round two shows iteration doesn't help, the claim goes.

## What this is trying to show

With incomplete data, a willingness to iterate, and the discipline to audit your own rubric, you can get to a defensible answer and know exactly how defensible it is.

That's the whole thing. I'm not a professional, I can't code, and I didn't record everything I should have. What I did was run the tests, log what I could, check my own scoring, and label the parts I couldn't check. The result is fine as long as we're willing to iterate on it.

Next I test whether iteration rescues a small model — with a perturbed source and a second scorer blind to the writer. Then model selection for reasoning, agentic workflows, OCR, embedding, and reranking, each with its own rubric.

The essay is in this repo: essay.md. The full map of the build is the next post. Fork it.