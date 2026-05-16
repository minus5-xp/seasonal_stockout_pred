from google.cloud import bigquery

client = bigquery.Client(project='thequantitativeledger', location='EU')

# Read and execute audit SQL
with open('99_leakage_audit_h12_v4_2.sql', 'r', encoding='utf-8') as f:
    sql = f.read()

# Find CREATE TABLE statement
stmt = [s.strip() for s in sql.split(';') if 'CREATE OR REPLACE TABLE' in s][0]
client.query(stmt).result()
print('✓ Audit table created\n')

# Query results
print('=' * 80)
print('AUDIT RESULTS')
print('=' * 80)
result = client.query('''
SELECT check_id, check_name, violations, status 
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_2_strict`
ORDER BY check_id
''').result()

for r in result:
    emoji = '✅' if r.status == 'PASS' else '❌'
    print(f"{emoji} Check {r.check_id}: {r.check_name}")
    print(f"   Status: {r.status}, Violations: {r.violations}")

# Final verdict
verdict = list(client.query('''
SELECT 
    CASE WHEN COUNTIF(status = "FAIL") = 0 THEN "PASS" ELSE "FAIL" END AS v,
    COUNTIF(status = "PASS") AS p,
    COUNT(*) AS t
FROM `thequantitativeledger.cruzber_models_eu.leakage_audit_h12_v4_2_strict`
''').result())[0]

print('=' * 80)
if verdict.v == 'PASS':
    print(f"✅ AUDIT PASSED: {verdict.p}/{verdict.t} checks")
else:
    print(f"❌ AUDIT FAILED: {verdict.p}/{verdict.t} checks")
print('=' * 80)
