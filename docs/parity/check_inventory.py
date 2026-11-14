#!/usr/bin/env python3
"""Structural coverage checks; never implies behavioral implementation passes."""
import json,pathlib
root=pathlib.Path(__file__).resolve().parent
inventory=json.loads((root/'capabilities.json').read_text())
rows=inventory['capabilities'];byid={r['id']:r for r in rows}
assert len(byid)==len(rows),'Duplicate capability IDs'
assert inventory['completion_claim'] is False
seed=json.loads((root/'seed-dispositions.json').read_text())
assert len(seed['definitions'])==seed['definition_count']==531
for d in seed['definitions']:
 assert d['disposition'] and set(d['capability_ids'])<=byid.keys(),d['symbol']
for row in rows:
 assert row['owner'] and row['acceptance_cases'],row['id']
 assert row['canonical_behavior_id'] in byid,row['id']
 assert row['command_contract']['identifier']==row['id']
 assert row['reference']['sources'],row['id']
seen=set()
for row in rows:
 chain=set();cur=row['id']
 while byid[cur]['canonical_behavior_id']!=cur:
  assert cur not in chain,'Alias cycle';chain.add(cur);cur=byid[cur]['canonical_behavior_id']
 seen.add(cur)
controls=json.loads((root/'dialog-surfaces.json').read_text())['controls']
assert all(c['id'] in byid for c in controls)
print(f'PASS: {len(rows)} required surfaces, {len(controls)} resource occurrences and all 531 seeds retained; aliases acyclic. Behavioral coverage remains unverified.')
