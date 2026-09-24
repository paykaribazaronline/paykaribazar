/**
 * Paykari Bazar — Express Application Setup.
 *
 * Configures middleware, raw body preservation for payment webhooks,
 * health-checks, and mounts the API & Webhook routers.
 */
import express from "express";
import cors from "cors";
import { apiRouter, webhookRouter } from "./apiRouter";

export const app = express();

// Enable CORS for all origins (mobile apps, admin dashboard, web client)
app.use(
  cors({
    origin: true,
    credentials: true,
  }),
);

// Parse JSON with rawBody preservation (critical for bKash/Nagad/SSLCommerz HMAC signature verification)
app.use(
  express.json({
    limit: "10mb",
    verify: (req: any, _res, buf) => {
      req.rawBody = buf;
    },
  }),
);

app.use(
  express.urlencoded({
    extended: true,
    limit: "10mb",
    verify: (req: any, _res, buf) => {
      req.rawBody = buf;
    },
  }),
);

// Root and Health Check routes (used by Render, UptimeRobot, or container checks)
app.get("/", (_req, res) => {
  res.json({
    ok: true,
    service: "paykaribazar-backend-api",
    version: "1.0.0",
    time: new Date().toISOString(),
  });
});

app.get("/health", (_req, res) => {
  res.status(200).json({
    status: "healthy",
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: Date.now(),
  });
});

// Mount routes
app.use("/api", apiRouter);
app.use("/webhooks", webhookRouter);
