#!/usr/bin/env python3
"""Compare an option inside one run made with --metal_ab_period=N.

Usage: ab_pairs.py perf.csv N

Blocks of N swaps alternate: even blocks have the option on, odd blocks off.
Each off block is compared with its two neighbouring on blocks, skipping
block edges (shader compiles at the switch), intros and scene changes.
"""
import csv,sys,statistics as st
P=int(sys.argv[2]); rows=[r for r in csv.DictReader(open(sys.argv[1])) if all(v not in ('',None) for v in r.values())]
blocks={}
for i,r in enumerate(rows):
    b=(i+1)//P; off=(i+1)%P
    if off<10 or off>P-3: continue  # skip edges (shader compiles at switch)
    blocks.setdefault(b,[]).append((float(r['frame_time_us'])/1000, float(r['draw_calls'])))
ratios=[]; out=[]
ks=sorted(blocks)
for k in ks:
    if k%2==1 and k-1 in blocks and k+1 in blocks:   # odd block = option OFF; neighbours ON
        off=st.median(f for f,_ in blocks[k]); on=st.median([f for f,_ in blocks[k-1]]+[f for f,_ in blocks[k+1]])
        d_off=st.median(d for _,d in blocks[k]); d_on=st.median([d for _,d in blocks[k-1]]+[d for _,d in blocks[k+1]])
        if d_on<500 or abs(d_on-d_off)/max(d_on,1)>0.15: continue  # skip intros and scene changes
        ratios.append(on/off); out.append((k,on,off,d_on,d_off))
for k,on,off,d1,d2 in out[:40]: print(f"block {k:3d}: ON {on:6.1f} ms  OFF {off:6.1f} ms  draws {d1:.0f}/{d2:.0f}")
if ratios: print(f"paired blocks {len(ratios)}: median ON/OFF frame-time ratio {st.median(ratios):.3f} (range {min(ratios):.2f}-{max(ratios):.2f})")
