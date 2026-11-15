#!/usr/bin/env python3
"""Read the compact requirement matrix; metadata checks never certify behavior."""
import argparse
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def requirements(matrix):
    """Expand lossless defaults/templates; assessments are deliberately separate."""
    rows = []
    for compact in matrix['requirements']:
        row = copy.deepcopy(matrix['row_defaults'])
        row.update(copy.deepcopy(compact))
        row.setdefault('expected_behavior', row['behavior'])
        row.setdefault('owner', row['family'])
        reference = copy.deepcopy(matrix['reference_defaults'])
        reference.update(row['reference'])
        row['reference'] = reference
        cases = []
        for compact_case in row['acceptance_cases']:
            case = copy.deepcopy(matrix['acceptance_templates'][compact_case['template']])
            case['id'] = compact_case.get('id', row['id'] + compact_case.get('suffix', ''))
            case['when'] = compact_case.get('when', row['behavior'])
            cases.append(case)
        row['acceptance_cases'] = cases
        row['command_contract'] = {**matrix['command_contract_defaults'], 'identifier': row['id']}
        rows.append(row)
    return rows


def assessed_rows(matrix):
    rows = requirements(matrix) + copy.deepcopy(matrix['automation_requirements'])
    for row in rows:
        row.update(copy.deepcopy(matrix['assessments'].get(row['id'], {})))
    return rows


def validate(root, matrix):
    if matrix['schema_version'] != 2 or matrix['completion_claim'] is not False:
        raise ValueError('Unsupported matrix or completion claim')
    rows = requirements(matrix)
    by_id = {row['id']: row for row in rows}
    if len(by_id) != len(rows):
        raise ValueError('Duplicate reference capability identifier')
    for row in rows:
        if not row['reference']['sources'] or not row['acceptance_cases']:
            raise ValueError('Missing source/acceptance requirement: ' + row['id'])
        visited = set()
        current = row['id']
        while by_id[current]['canonical_behavior_id'] != current:
            if current in visited:
                raise ValueError('Capability alias cycle: ' + current)
            visited.add(current)
            current = by_id[current]['canonical_behavior_id']
    for seed in matrix['reference_seeds']:
        if not set(seed['capability_ids']).issubset(by_id):
            raise ValueError('Unresolved reference seed: ' + seed['symbol'])
    all_ids = set(by_id) | {row['id'] for row in matrix['automation_requirements']}
    for identifier, assessment in matrix['assessments'].items():
        if identifier not in all_ids or not assessment['implementation_paths'] or not assessment['checks']:
            raise ValueError('Incomplete assessment: ' + identifier)
        for evidence in assessment['implementation_paths'] + assessment['checks']:
            path = root / evidence['path']
            if not path.is_file() or evidence['symbol'] not in path.read_text(encoding='utf-8'):
                raise ValueError('Assessment path/symbol no longer exists: ' + identifier + ': ' + evidence['path'])
    return len(rows), len(matrix['automation_requirements']), len(matrix['assessments'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expand', action='store_true', help='print expanded requirements and dated assessments')
    args = parser.parse_args()
    matrix = json.loads((ROOT / 'docs/parity/capabilities.json').read_text(encoding='utf-8'))
    counts = validate(ROOT, matrix)
    if args.expand:
        print(json.dumps(assessed_rows(matrix), indent=2, ensure_ascii=False))
    else:
        print('PASS capability metadata: %d reference surfaces, %d automation requirements, %d dated source/check mappings. Not behavioral acceptance.' % counts)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit('Capability metadata stopped: ' + str(error))
