# Geeking Dashboard Deployment — Next Steps

## What's Done
- Created all files for the `commonsense-geeking` GitHub repository:
  - `index.html` (main dashboard)
  - `apps.json` (app data)
  - `robots.txt` (search engine blocking)
  - `.gitignore` (git ignore rules)
  - `README.md` (setup instructions)
- All files are ready to push to GitHub

## What's Left to Do

### Step 1: Create GitHub Repo & Push Files
1. Go to https://github.com/new
2. Create public repo named `commonsense-geeking`
3. **Do NOT initialize** with README (you'll push files)
4. Click "Create repository"
5. Copy the repo URL (will be `https://github.com/YOUR_USERNAME/commonsense-geeking.git`)

**From your terminal**, in the folder with these files:
```bash
git init
git add .
git commit -m "Initial commit: Commonsense Geeking dashboard"
git remote add origin https://github.com/YOUR_USERNAME/commonsense-geeking.git
git branch -M main
git push -u origin main
```

### Step 2: Deploy to Cloudflare Pages
1. Go to https://dash.cloudflare.com/efa2fe3fcb74d5e435d230c4cb1445cb/pages
2. Look for **"commonsense-geeking"** project (it should be there from earlier setup)
3. In the project settings:
   - Confirm build settings are:
     - Framework: None
     - Build command: (empty)
     - Build output directory: `/`
4. Click **"Save and Deploy"** button
5. Wait for deployment to complete (1-2 minutes)

### Step 3: Add Custom Domain
1. After deployment succeeds, click on the **"commonsense-geeking"** project
2. Go to **Settings** → **Custom domain**
3. Enter: `geeking.commonsense.com.au`
4. Follow Cloudflare's DNS instructions (add CNAME record to Cloudflare DNS for commonsense.com.au)
5. Confirm when DNS propagates

## Key URLs
- **GitHub Repo**: https://github.com/YOUR_USERNAME/commonsense-geeking
- **Cloudflare Dashboard**: https://dash.cloudflare.com/efa2fe3fcb74d5e435d230c4cb1445cb/pages
- **Final Site**: https://geeking.commonsense.com.au (once deployed)

## Files Ready to Upload
All these files are in `/mnt/user-data/outputs/`:
- `index.html`
- `apps.json`
- `robots.txt`
- `.gitignore`
- `README.md`

## Notes
- Local IP apps (192.168.1.x) only work from home network — will need Cloudflare Tunnel for remote access (Phase 2)
- Apps.json has all apps configured (Solar, Trading, Scripts)
- Search engines blocked via robots.txt
- Dark mode toggle works with localStorage persistence
