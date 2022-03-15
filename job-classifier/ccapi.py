import requests

CC_BACKEND = 'http://localhost:8080'
JWT = 'eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJyb2xlcyI6WyJhcGkiXSwic3ViIjoiYXBpIn0.uWDoxrv6JrlYyAzqSIl7cBYvnqusDkvIpV5JJDYhXF64Tk3d42z-tKbfPdbiRNVAYxhnUQGf_RNujblV8Eg0DQ'

# Returns an array of jobs
def fetchJobs(startTimeStart, startTimeEnd, cluster, states):
    page, itemsPerPage = 1, 50
    states = '&'.join(map(lambda state: f"state={state}", states))
    url = f"{CC_BACKEND}/api/jobs/?cluster={cluster}&{states}&start-time={startTimeStart}-{startTimeEnd}&items-per-page={itemsPerPage}"

    jobs = []
    while True:
        res = requests.get(
            url=f"{url}&page={page}",
            headers={'Authorization': f"Bearer {JWT}"})
        if not res.ok:
            raise Exception(f"request failed ({res.status_code}): {res.text}")

        page += 1
        data = res.json()['jobs']
        jobs.extend(data)
        if len(data) < itemsPerPage:
            break

    return jobs

def tagJob(job, tag):
    res = requests.post(
        url=f"{CC_BACKEND}/api/jobs/tag_job/{job['id']}",
        json=[{"name": tag["name"], "type": tag["type"]}],
        headers={'Authorization': f"Bearer {JWT}"})
    if not res.ok:
        raise Exception(f"request failed ({res.status_code}): {res.text}")
