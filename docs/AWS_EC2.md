# Optional: deploying to AWS EC2

> ⚠️ **Cost warning.** Everything else in SecureShip is free. EC2 is not guaranteed to be.
> - AWS's free tier is limited in time and amount, and its terms have changed over the years. Check the current offer on the AWS Free Tier page for *your* account.
> - Public IPv4 addresses are billed hourly.
> - EBS storage, snapshots and data transfer can also cost money.
>
> Before launching anything:
> 1. Create a **Budget** with an email alert (Billing → Budgets → e.g. $1).
> 2. **Stop** the instance after every demo.
> 3. **Terminate** it, and release any Elastic IP, when you're done.

The pipeline doesn't change. Only the target does: you point `DEPLOY_HOST` at the instance.

## 1. Launch the instance

| Setting | Value |
|---|---|
| AMI | Ubuntu Server 24.04 LTS |
| Type | the free-tier-eligible type offered to your account. The ShopPilot backend with EasyOCR needs ~1.5 GB RAM, so a 1 GB instance needs a swap file (step 3). |
| Key pair | create one for **your** admin access (separate from the pipeline's deploy key) |
| Storage | 20–30 GB gp3 |

## 2. Security Group (the cloud firewall)

| Type | Port | Source | Purpose |
|---|---|---|---|
| SSH | 22 | **My IP** only | your admin access + Jenkins deploys (Jenkins runs on your laptop, same IP) |
| Custom TCP | 8080 | **My IP** only | view the app and run the ZAP scan |

- **No** rule for 5432 (PostgreSQL). It isn't published by Docker either.
- **No** `0.0.0.0/0` rules.
- To share the app publicly, use a **Cloudflare Tunnel** on the instance: set `PUBLIC_BIND=127.0.0.1` in `/opt/secureship/.env` and run `cloudflared tunnel --url http://localhost:8080`. Then port 8080 can stay closed entirely.
- When your home IP changes, update the rules.

## 3. Prepare the server (one time)

```bash
scp -i my-admin-key.pem target/setup-target.sh ci/lab-target/bootstrap-env.sh ci/keys/deploy_ed25519.pub ubuntu@<EC2_DNS>:
ssh -i my-admin-key.pem ubuntu@<EC2_DNS> 'sudo bash setup-target.sh deploy_ed25519.pub'

# small instance? add 2 GB swap so PyTorch/EasyOCR fits
ssh -i my-admin-key.pem ubuntu@<EC2_DNS> 'sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile && echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab'
```

`setup-target.sh` sets up:
- Docker from the official repository
- the `deploy` user (key-only)
- hardened sshd: no root login, no passwords
- the `ufw` firewall
- automatic security updates
- `/opt/secureship/.env` with random secrets

## 4. Point Jenkins at EC2

In Jenkins: *Manage Jenkins → System → Global properties → Environment variables*:

| Name | Value |
|---|---|
| `DEPLOY_HOST` | `<EC2 public DNS>` |
| `DEPLOY_USER` | `deploy` |
| `APP_PUBLIC_URL` | `http://<EC2 public DNS>:8080` |
| `HEALTH_TIMEOUT` | `240` (small instances start slower) |

Global properties override the container's defaults. Then run the job.

The first transfer of the backend image over SSH takes a while (it's large). Later builds only send changed images.

## 5. After deploying (and before claiming it on your resume)

Keep proof:
- the Jenkins build showing `DEPLOYED` to the EC2 host
- the evidence report
- a screenshot of the Security Group rules
- a screenshot of the app on the EC2 address

Then **stop or terminate the instance**.

## Clean-up checklist

- [ ] Instance terminated
- [ ] Elastic IP released (if you allocated one)
- [ ] Unattached EBS volumes and snapshots deleted
- [ ] Budget alert left on
