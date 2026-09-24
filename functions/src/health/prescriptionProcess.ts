/**
 * Healthcare-domain prescription analyser.
 *
 * Security posture:
 *   - Callable `analyzePrescription`. Caller must be `admin` or `staff`
 *     (the "doctor" surface). A customer cannot call this directly — the
 *     Flutter client submits an upload through a separate intake path, an
 *     admin/doctor opens it and calls this function.
 *   - Reads the image from Cloud Storage via admin SDK (so Storage rules can
 *     stay strict). Passes the image to Gemini Vision.
 *   - Returns structured medicines. Does NOT write products / inventory.
 *   - Stores the structured result in `prescriptions/{id}` for the doctor's
 *     records. Reads/writes are gated by Firestore rules to admin/staff only.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertRole, FieldValue, Timestamp } from "../admin";
import { errInvalidArgument, errFailedPrecondition, errInternal } from "../shared/security";
import { recordAudit } from "../audit/auditLog";
import { httpClient, sanitise } from "../payments/_http";

const GEMINI_API_KEY = process.env.GEMINI_API_KEY ?? "";
const GEMINI_ENDPOINT =
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent";

interface MedicineSuggestion {
  name: string;
  nameBn?: string;
  dosage?: string;
  frequency?: string;
  duration?: string;
  notes?: string;
}

export interface AnalyzePrescriptionInput {
  storagePath: string; // e.g. "prescriptions/uid/file.jpg"
  patientName?: string;
  patientAge?: number;
}

export interface AnalyzePrescriptionResult {
  prescriptionId: string;
  medicines: MedicineSuggestion[];
  rawText: string;
  warnings: string[];
}

export const analyzePrescription = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const caller = assertRole(req, ["admin", "staff"]);
    const uid = caller.uid;
    const input = (req.data ?? {}) as Partial<AnalyzePrescriptionInput>;
    const storagePath = (input.storagePath ?? "").toString().trim();
    const patientName = input.patientName?.toString().trim();
    const patientAge = input.patientAge;

    if (!storagePath) errInvalidArgument("storagePath is required.");
    if (!GEMINI_API_KEY) {
      errInternal("GEMINI_API_KEY is not configured.");
    }

    // Build the public-read URL the Gemini API can fetch. The Storage rules
    // must allow this service account to read the object.
    const imageUrl = `https://firebasestorage.googleapis.com/v0/b/${
      process.env.GCLOUD_PROJECT
    }/o/${encodeURIComponent(storagePath)}?alt=media`;

    const prompt = `You are an expert pharmacist. Analyse the prescription
image. Return JSON only with this exact shape:
{
  "medicines": [{ "name": "", "nameBn": "", "dosage": "", "frequency": "", "duration": "", "notes": "" }],
  "rawText": "<full transcription>",
  "warnings": ["<safety flags, e.g. illegible section, expired drug>]
}
Do not invent medicines not present in the image.`;

    let parsed: {
      medicines?: MedicineSuggestion[];
      rawText?: string;
      warnings?: string[];
    };

    try {
      const res = await httpClient({
        baseURL: "",
        timeoutMs: 45000,
      }).post(
        `${GEMINI_ENDPOINT}?key=${GEMINI_API_KEY}`,
        {
          contents: [
            {
              role: "user",
              parts: [
                { text: prompt },
                { file_data: { mime_type: "image/jpeg", file_uri: imageUrl } },
              ],
            },
          ],
          generationConfig: {
            temperature: 0.1,
            response_mime_type: "application/json",
          },
        },
      );
      const text = res.data?.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
      try {
        parsed = JSON.parse(text);
      } catch {
        errFailedPrecondition(
          "Gemini response was not valid JSON; retry with a clearer image.",
          { raw: text.slice(0, 500) },
        );
      }
    } catch (err) {
      console.error("[analyzePrescription] Gemini call failed:", err);
      errInternal("Failed to analyse prescription with Gemini.");
    }

    const prescriptionRef = db.collection("prescriptions").doc();
    const docData = {
      id: prescriptionRef.id,
      storagePath,
      imageUrl,
      patientName: patientName ?? null,
      patientAge: patientAge ?? null,
      analysedBy: uid,
      analysedAt: FieldValue.serverTimestamp(),
      serverAnalysedAt: Timestamp.now(),
      medicines: parsed.medicines ?? [],
      rawText: parsed.rawText ?? "",
      warnings: parsed.warnings ?? [],
      // We DO NOT link to productIds or modify inventory — that is an admin
      // decision the doctor must make separately.
    };
    await prescriptionRef.set(docData);

    await recordAudit({
      actorUid: uid,
      action: "prescription.analysed",
      targetType: "prescription",
      targetId: prescriptionRef.id,
      after: sanitise({
        medicinesCount: (parsed.medicines ?? []).length,
        warnings: parsed.warnings ?? [],
        patientName,
      }),
    });

    return {
      prescriptionId: prescriptionRef.id,
      medicines: parsed.medicines ?? [],
      rawText: parsed.rawText ?? "",
      warnings: parsed.warnings ?? [],
    } satisfies AnalyzePrescriptionResult;
  },
);
