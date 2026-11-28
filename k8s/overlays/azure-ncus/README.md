# Overlay `azure-ncus`

Deploys Vankoo to the AKS cluster `vankoo-aks-ncus` (resource group `liquilabs-vankoo-prod`, North Central US), in Anjali's subscription. It inherits everything from `../azure` and only changes the image registry (`vankooacrncusxjh8`) and the public host (`vankoo-liquilabs.northcentralus.cloudapp.azure.com`).

## Current state (27 Nov 2026, after the final presentation)

The cluster is **stopped and scaled down to one node** to save credit, without deleting anything:

| Item | State |
| --- | --- |
| AKS `vankoo-aks-ncus` | `Stopped` |
| Node pool `system` | 1 node (normally 2) |
| Node pool `extra` | 0 nodes (normally 1) |
| Function `vankoo-dni-verification-ncus` | `Stopped` |

All Vankoo pods need about 48 GB of memory, so **one node is not enough to run the app**. Scale back up before using it.

## Turning it back on

Start about an hour before you need it. Set `SUB` to the subscription id first.

```bash
az aks start --subscription "$SUB" -g liquilabs-vankoo-prod -n vankoo-aks-ncus
az aks nodepool scale --subscription "$SUB" -g liquilabs-vankoo-prod --cluster-name vankoo-aks-ncus -n system --node-count 2
az aks nodepool scale --subscription "$SUB" -g liquilabs-vankoo-prod --cluster-name vankoo-aks-ncus -n extra --node-count 1
az functionapp start --subscription "$SUB" -g liquilabs-vankoo-prod -n vankoo-dni-verification-ncus
az aks get-credentials --subscription "$SUB" -g liquilabs-vankoo-prod -n vankoo-aks-ncus --overwrite-existing
kubectl -n vankoo get pods
```

Then check that Argo CD is `Synced/Healthy` and that the public URL answers 200.

- The risk service reloads the SUNAT registry when it starts. If a new MYPE KYC will be shown, seed the demo RUC again after the reload finishes.
- If the cluster will host **another project** instead of Vankoo, decide first what to do with the Vankoo workloads.

## Stopping it again

```bash
az aks nodepool scale --subscription "$SUB" -g liquilabs-vankoo-prod --cluster-name vankoo-aks-ncus -n extra --node-count 0
az aks nodepool scale --subscription "$SUB" -g liquilabs-vankoo-prod --cluster-name vankoo-aks-ncus -n system --node-count 1
az aks stop --subscription "$SUB" -g liquilabs-vankoo-prod -n vankoo-aks-ncus
az functionapp stop --subscription "$SUB" -g liquilabs-vankoo-prod -n vankoo-dni-verification-ncus
```
