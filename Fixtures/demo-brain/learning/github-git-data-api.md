# GitHub Git Data API cheat sheet
1. `GET /git/ref/heads/main` (send `If-None-Match` for a cheap 304)
2. `POST /git/trees` with `base_tree`
3. `POST /git/commits`
4. `PATCH /git/refs/heads/main` with `force: false` → 422 means someone moved the branch first
