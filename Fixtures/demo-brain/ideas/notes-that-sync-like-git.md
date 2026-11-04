# Notes that sync like git, without git
Users should never see the word "commit". They see: saved on device → syncing → synced.
Underneath, every batch is one commit and the branch only moves with compare-and-swap.
