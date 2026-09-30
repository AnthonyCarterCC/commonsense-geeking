# Commonsense Geeking

Central hub for scripts, tools, and applications.

## Setup Instructions

### 1. Create a New GitHub Repository

1. Go to [github.com/new](https://github.com/new)
2. Name it: `commonsense-geeking` (or similar)
3. Make it **Public** (required for Cloudflare Pages)
4. Do NOT initialize with README (you'll push files)
5. Click "Create repository"

### 2. Initialize Git Locally and Push

```bash
# Navigate to the folder with these files
cd path/to/commonsense-geeking

# Initialize git
git init

# Add all files
git add .

# Create initial commit
git commit -m "Initial commit: Commonsense Geeking dashboard"

# Add remote (replace YOUR_USERNAME with your GitHub username)
git remote add origin https://github.com/YOUR_USERNAME/commonsense-geeking.git

# Push to GitHub
git branch -M main
git push -u origin main
```

### 3. Deploy to Cloudflare Pages

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Go to **Pages** → **Create a project**
3. Select **Connect to Git**
4. Select your GitHub account and the `commonsense-geeking` repo
5. Build settings:
   - **Framework preset**: None
   - **Build command**: (leave empty)
   - **Build output directory**: `/` (root)
6. Click **Save and Deploy**
7. Once deployed, note the Cloudflare Pages URL (e.g., `https://commonsense-geeking.pages.dev`)

### 4. Set Up Custom Domain

1. In Cloudflare Dashboard, go to your project
2. **Settings** → **Custom domain**
3. Enter: `geeking.commonsense.com.au`
4. Follow DNS setup instructions (add CNAME record to Cloudflare DNS)

## File Structure

```
commonsense-geeking/
├── index.html          # Main dashboard page
├── robots.txt          # Block search engine indexing
├── README.md           # This file
├── .gitignore          # Git ignore rules
└── data/
    └── apps.json       # All apps & metadata
```

## How to Update Apps

1. Edit `data/apps.json`
2. Add or modify app entries with:
   - `id`: Unique identifier
   - `title`: App name
   - `category`: One of: `solar`, `trading-apps`, `trading-indicators`, `scripts`
   - `link`: URL to the app
   - `icon`: Emoji icon
   - `description`: One-sentence description

3. Commit and push:
```bash
git add data/apps.json
git commit -m "Add new app: [App Name]"
git push
```

Cloudflare Pages will auto-deploy within 1-2 minutes.

## Categories

- **solar**: Solar & Energy monitoring apps
- **trading-apps**: Trading dashboards and tools
- **trading-indicators**: thinkorSwim shared studies and indicators
- **scripts**: PowerShell scripts and utilities

## Notes

- Links to local IP addresses (192.168.1.200:xxxx) only work from within your home network
- Dark mode preference is saved in browser localStorage
- robots.txt blocks search engine indexing
- All links open in a new tab

## Future Enhancements

- Add live status checks for apps
- Cloudflare Tunnel for remote access
- Admin interface for managing apps without code
- API status indicators
