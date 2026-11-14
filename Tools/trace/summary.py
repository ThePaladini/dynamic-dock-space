import sys
# groups height changes into animations (gap > 0.25 s) and reports distinct frames and the longest freeze
rows = [tuple(map(float, l.split())) for l in open(sys.argv[1]) if l.strip()]
groups, cur = [], []
for t, h in rows[1:]:
    if cur and t - cur[-1][0] > 0.25: groups.append(cur); cur = []
    cur.append((t, h))
if cur: groups.append(cur)
for g in groups:
    if len(g) < 2 and abs(g[0][1]) < 1: continue
    d = g[-1][0] - g[0][0]
    gaps = [b[0] - a[0] for a, b in zip(g, g[1:])]
    print(f"t={g[0][0]:6.2f}s {g[0][1]:.0f}->{g[-1][1]:.0f}  {len(g):3d} frames in {d*1000:4.0f} ms  longest freeze {max(gaps)*1000 if gaps else 0:4.0f} ms")
