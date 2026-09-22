Haiku + proxemics/repetition rule

Same model as baseline (claude-haiku-4-5). System prompt gained two rules:
physical distance is scored as its own signal (closing distance reads as
confidence, growing/staying distant reads as hesitancy even with a polite
line), and repeating an already-ignored line without changing approach
reads as tone-deaf rather than persistent. Written to fix seed_B/seed_C,
which failed on both models in round 1 because the prompt never told the
judge distance mattered.
