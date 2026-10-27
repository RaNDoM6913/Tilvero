#!/usr/bin/env python3
"""Read-only process CPU/RSS sampling; no elevated permissions or power settings."""
import argparse, csv, subprocess, time, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('pid',type=int);p.add_argument('--seconds',type=int,default=600);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
def cpu_seconds(value):
 parts=value.split(':');return sum(float(x)*60**i for i,x in enumerate(reversed(parts)))
rows=[];start=time.monotonic()
while True:
 result=subprocess.run(['/bin/ps','-p',str(a.pid),'-o','time=,rss='],capture_output=True,text=True)
 if result.returncode: break
 values=result.stdout.split();rows.append({'elapsed':time.monotonic()-start,'cpu_seconds':cpu_seconds(values[0]),'rss_kib':int(values[1])})
 if rows[-1]['elapsed']>=a.seconds: break
 time.sleep(min(10,max(0,a.seconds-(time.monotonic()-start))))
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps({'pid':a.pid,'samples':rows,'meanCPUPercent':100*(rows[-1]['cpu_seconds']-rows[0]['cpu_seconds'])/(rows[-1]['elapsed']-rows[0]['elapsed']) if len(rows)>1 else None,'peakRSSMiB':max((r['rss_kib'] for r in rows),default=0)/1024,'scope':'Process CPU time delta and resident memory. Other system workload uncontrolled; wakeups not measured.'},indent=2)+'\n')
print(a.output)
