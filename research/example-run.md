# End-to-end: Cortex-managed executable entities

## 1. Define `Gene/test`
```bash
cortex_property_define entity_type=Gene property=test 
  body='"${entity} @ ${inputs[:treatment]} (${inputs[:treatment].length})"'
  description='Smoke' property_type=single result_type=text
  arguments='[{"name":"treatment","type":"string","required":true}]'
  dependencies='[]' agent=E2E
```
08/25/26-23:15:28.254[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_property_define[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_define/Gene_c072613c21aff2bbc02ddcb58ca3e2eb.json[0m
[0m08/25/26-23:15:28.265[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_property_define[0m [36m0.013″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_define/Gene_c072613c21aff2bbc02ddcb58ca3e2eb.json[0m
[0m08/25/26-23:15:28.274[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_entity_property[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_2f83533ec9fde6033e9e3acc30f69d58.json[0m
[0m08/25/26-23:15:28.291[34m[4][0m [1m[0m[35mstart[0m [0m[33mtest[0m [34m/home/mvazque2/.scout/var/jobs/Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232[0m
[0m08/25/26-23:15:28.296[34m[4][0m [1m[0m[32mdone[0m [0m[33mtest[0m [36m0.0064″[0m [34m/home/mvazque2/.scout/var/jobs/Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232[0m
[0m08/25/26-23:15:28.300[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_entity_property[0m [36m0.027″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_2f83533ec9fde6033e9e3acc30f69d58.json[0m
[0m08/25/26-23:15:28.308[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_entity_property[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_2f83533ec9fde6033e9e3acc30f69d58.json[0m
[0m08/25/26-23:15:28.316[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_entity_property[0m [36m0.01″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_2f83533ec9fde6033e9e3acc30f69d58.json[0m
[0m08/25/26-23:15:28.325[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_entity_property[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_a73ea05e5a94eccd61a893b37b644b9f.json[0m
[0m08/25/26-23:15:28.338[34m[4][0m [1m[0m[35mstart[0m [0m[33mtest[0m [34m/home/mvazque2/.scout/var/jobs/Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232[0m
[0m08/25/26-23:15:28.342[34m[4][0m [1m[0m[32mdone[0m [0m[33mtest[0m [36m0.006″[0m [34m/home/mvazque2/.scout/var/jobs/Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232[0m
[0m08/25/26-23:15:28.346[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_entity_property[0m [36m0.023″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_a73ea05e5a94eccd61a893b37b644b9f.json[0m
[0m08/25/26-23:15:28.358[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_property_define[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_define/Gene_640d873151898ccb43ac8e4832f19064.json[0m
[0m08/25/26-23:15:28.375[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_property_define[0m [36m0.02″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_define/Gene_640d873151898ccb43ac8e4832f19064.json[0m
[0m08/25/26-23:15:28.385[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_property_define[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_define/Gene_ba60b13d71507315f05cae01adccd5d3.json[0m
[0m08/25/26-23:15:28.393[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_property_define[0m [36m0.01″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_define/Gene_ba60b13d71507315f05cae01adccd5d3.json[0m
[0m08/25/26-23:15:28.401[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_entity_property[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_f8c8ba8dac7952ad98d45e189988d99e.json[0m
[0m08/25/26-23:15:28.425[34m[4][0m [1m[0m[35mstart[0m [0m[33mraw_v[0m [34m/home/mvazque2/.scout/var/jobs/Gene/raw_v/Tp53_daa0f32413a82efe2cd00927d5aef3e0[0m
[0m08/25/26-23:15:28.428[34m[4][0m [1m[0m[32mdone[0m [0m[33mraw_v[0m [36m0.0055″[0m [34m/home/mvazque2/.scout/var/jobs/Gene/raw_v/Tp53_daa0f32413a82efe2cd00927d5aef3e0[0m
[0m08/25/26-23:15:28.432[34m[4][0m [1m[0m[35mstart[0m [0m[33mderived[0m [34m/home/mvazque2/.scout/var/jobs/Gene/derived/Tp53_995791d2690c519f5063b86e421b4673[0m
[0m08/25/26-23:15:28.438[34m[4][0m [1m[0m[32mdone[0m [0m[33mderived[0m [36m0.0078″[0m [34m/home/mvazque2/.scout/var/jobs/Gene/derived/Tp53_995791d2690c519f5063b86e421b4673[0m
[0m08/25/26-23:15:28.442[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_entity_property[0m [36m0.042″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_f8c8ba8dac7952ad98d45e189988d99e.json[0m
[0m08/25/26-23:15:28.450[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_property_update[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_update/Gene_054b64c7a8f08e556651b986e304a7f2.json[0m
[0m08/25/26-23:15:28.461[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_property_update[0m [36m0.014″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_property_update/Gene_054b64c7a8f08e556651b986e304a7f2.json[0m
[0m08/25/26-23:15:28.468[34m[4][0m [1m[0m[35mstart[0m [0m[33mcortex_entity_property[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_f8c8ba8dac7952ad98d45e189988d99e.json[0m
[0m08/25/26-23:15:28.493[34m[4][0m [1m[0m[35mstart[0m [0m[33mraw_v[0m [34m/home/mvazque2/.scout/var/jobs/Gene/raw_v/Tp53_8a4a3e4d7e0cfbec5d0291fcc05d89e7[0m
[0m08/25/26-23:15:28.497[34m[4][0m [1m[0m[32mdone[0m [0m[33mraw_v[0m [36m0.0054″[0m [34m/home/mvazque2/.scout/var/jobs/Gene/raw_v/Tp53_8a4a3e4d7e0cfbec5d0291fcc05d89e7[0m
[0m08/25/26-23:15:28.500[34m[4][0m [1m[0m[35mstart[0m [0m[33mderived[0m [34m/home/mvazque2/.scout/var/jobs/Gene/derived/Tp53_53db0a650533d233c5d75e239d53ea13[0m
[0m08/25/26-23:15:28.505[34m[4][0m [1m[0m[32mdone[0m [0m[33mderived[0m [36m0.0064″[0m [34m/home/mvazque2/.scout/var/jobs/Gene/derived/Tp53_53db0a650533d233c5d75e239d53ea13[0m
[0m08/25/26-23:15:28.509[34m[4][0m [1m[0m[32mdone[0m [0m[33mcortex_entity_property[0m [36m0.042″[0m [34m/home/mvazque2/.scout/var/jobs/Cortex/cortex_entity_property/Gene_f8c8ba8dac7952ad98d45e189988d99e.json[0m
[0m```json
{
  "address": "Gene/test",
  "version": 1,
  "digest": "f6058baab54d9da49fd7923a9e2b2b46014f68ef4a3803070ec179a3f63b8ae3",
  "defined": true
}
```
## 2. Execute for Tp53
```json
{
  "entity_type": "Gene",
  "entity": "Tp53",
  "property": "test",
  "arguments": {
    "treatment": "PD"
  },
  "definition_version": 1,
  "definition_digest": "f6058baab54d9da49fd7923a9e2b2b46014f68ef4a3803070ec179a3f63b8ae3",
  "property_job": "Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232",
  "result": "Tp53 @ PD (2)"
}
```
## 3. Repeat: same path, no recompute
```json
{
  "entity_type": "Gene",
  "entity": "Tp53",
  "property": "test",
  "arguments": {
    "treatment": "PD"
  },
  "definition_version": 1,
  "definition_digest": "f6058baab54d9da49fd7923a9e2b2b46014f68ef4a3803070ec179a3f63b8ae3",
  "property_job": "Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232",
  "result": "Tp53 @ PD (2)"
}
```
_cached: identical receipt, same `property_job`, no new step_
## 4. `update=true` recomputes at the same path
```json
{
  "entity_type": "Gene",
  "entity": "Tp53",
  "property": "test",
  "arguments": {
    "treatment": "PD"
  },
  "definition_version": 1,
  "definition_digest": "f6058baab54d9da49fd7923a9e2b2b46014f68ef4a3803070ec179a3f63b8ae3",
  "property_job": "Gene/test/Tp53_69a89f6deb2e538df44970e3365e1232",
  "result": "Tp53 @ PD (2)"
}
```
## 5. Dependency variant
```json
{
  "entity_type": "Gene",
  "entity": "Tp53",
  "property": "derived",
  "arguments": {
    "treatment": "a"
  },
  "definition_version": 1,
  "definition_digest": "07296898c99af32b5a8c0fd8ba064ed038568e14f43a553b4b28653c7fd85d49",
  "property_job": "Gene/derived/Tp53_995791d2690c519f5063b86e421b4673",
  "result": "D(Tp53:a)"
}
```
## 6. Update the dependency: both job paths change
```json
{
  "entity_type": "Gene",
  "entity": "Tp53",
  "property": "derived",
  "arguments": {
    "treatment": "a"
  },
  "definition_version": 1,
  "definition_digest": "07296898c99af32b5a8c0fd8ba064ed038568e14f43a553b4b28653c7fd85d49",
  "property_job": "Gene/derived/Tp53_53db0a650533d233c5d75e239d53ea13",
  "result": "D(Tp53!a)"
}
```
_dependency update invalidated the derived job: new path + new result_

# E2E OK — 2026-08-25 23:15:28 +0200

_Scratch storage `/bulk/mvazque2/git/workflows/Cortex/tmp/e2e_var` is removed at the end of the run._
