# Sync edge cases · 2 Nov
Walked through the scary cases:
1. Two devices edit the same line → keep GitHub's version, my version goes to the Inbox as a conflict copy
2. Lost response after pushing → read the ref, check whether our commit landed before retrying
3. Note deleted remotely while I'm editing it → restore mine as a copy

Nobody loses text. That's the whole rule.
