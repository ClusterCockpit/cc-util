#!/usr/bin/env python3

import json
import ccapi

# Applies the action
def applyAction(job, action):
    print(f"job#{job['id']}: -> action {action}...")

    if action['type'] == 'add-tag':
        ccapi.tagJob(job, action['value'])
    else:
        raise Exception(f"unkown action type: {action['type']}")

# Checks if a condition matches the job
def checkCondition(job, cond):
    stats = job['statistics']
    if cond['metric'] not in stats:
        return None

    stat = stats[cond['metric']][cond['stat']]
    val = cond['value']
    if cond['cond'] == '=':
        return stat == val
    elif cond['cond'] == '<':
        return stat < val
    elif cond['cond'] == '>':
        return stat > val
    else:
        raise Exception(f"unknown condition operator: {cond['cond']}")

def handleRules(rules, startTimeStart, startTimeEnd):
    jobs = ccapi.fetchJobs(
        startTimeStart=startTimeStart, startTimeEnd=startTimeEnd, cluster=rules['cluster'],
        states=['completed', 'failed', 'cancelled', 'stopped', 'timeout', 'preempted', 'out_of_memory'])

    for job in jobs:
        if 'statistics' not in job:
            continue

        for rule in rules['rules']:
            condMatched = False
            for cond in rule['conditions']:
                condMatched = condMatched or checkCondition(job, cond)

            if condMatched:
                for action in rule['actions']:
                    applyAction(job, action)

def main():
    # Fetch jobs from past hour:
    # startTimeEnd = int(time.time())
    # startTimeStart = startTimeEnd - 60 * 60

    startTimeEnd = 1596282692 # A date from the var/jobs.db
    startTimeStart = startTimeEnd - 12 * 60 * 60

    with open('./rules.emmy.json', 'r') as f:
        rules = json.load(f)

    handleRules(rules, startTimeStart=startTimeStart, startTimeEnd=startTimeEnd)





if __name__ == '__main__':
    main()
