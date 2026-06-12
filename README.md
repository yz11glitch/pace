# Pace

Pace is a local-first money tracking prototype built with Next.js.

## Run Locally

Install dependencies and start the development server:

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Build

Create and run a production build:

```bash
npm run build
npm run start
```

Project checks:

```bash
npm run lint
npx tsc --noEmit
npm run build
```

## PWA Testing

iOS may cache Home Screen web app metadata. After changing icons or status bar
settings, delete the existing Home Screen icon and add Pace again.

## Data Storage

Pace currently stores transactions, settings, and theme preferences in the
browser's `localStorage`. Data stays in the current browser profile and is not
synced between devices. Clearing site data or using a different browser will
start with the prototype's default data.

There is no database, Supabase integration, or authentication yet.

## Deployment

The deployment target is [Vercel](https://vercel.com/). Import the repository
as a Next.js project and use Vercel's default build settings. No environment
variables are required for the current localStorage prototype.
