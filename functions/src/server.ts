/**
 * Paykari Bazar — Standalone HTTP Server Entry Point.
 *
 * Runs on Render.com, Docker, or local machine.
 * Usage:
 *   npm run dev    (local development with auto-reload)
 *   npm start      (production server: node lib/server.js)
 */
import "dotenv/config";
import "./admin"; // Initialize Firebase Admin SDK
import { app } from "./app";

const PORT = Number(process.env.PORT) || 5001;
const HOST = process.env.HOST || "0.0.0.0";

const server = app.listen(PORT, HOST, () => {
  console.log(`🚀 Paykari Bazar API server listening on http://${HOST}:${PORT}`);
  console.log(`📋 Health check: http://${HOST}:${PORT}/health`);
  console.log(`🔌 API endpoint: http://${HOST}:${PORT}/api/:functionName`);
  console.log(`🔔 Webhooks:     http://${HOST}:${PORT}/webhooks/:gateway`);
});

// Graceful shutdown
process.on("SIGTERM", () => {
  console.log("SIGTERM received. Shutting down gracefully...");
  server.close(() => {
    console.log("Server closed.");
    process.exit(0);
  });
});

process.on("SIGINT", () => {
  console.log("SIGINT received. Shutting down gracefully...");
  server.close(() => {
    console.log("Server closed.");
    process.exit(0);
  });
});
