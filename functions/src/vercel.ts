/**
 * Vercel Serverless Function entry point.
 * Exports the Express app instance for Vercel's Node.js runtime.
 */
import "./admin";
import { app } from "./app";

export default app;
