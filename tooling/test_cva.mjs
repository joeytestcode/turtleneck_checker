/**
 * CVA measurement test — compare current vs. improved prompt on all sample images.
 *
 * Usage:  node test_cva.mjs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dir = path.dirname(fileURLToPath(import.meta.url));
const SAMPLE_DIR = path.join(__dir, "../webapp_sample");
const API_KEY = fs
  .readFileSync(path.join(SAMPLE_DIR, ".env"), "utf8")
  .trim();
const MODEL = "gpt-4.1";

const SAMPLES = ["test1.jpg", "test2.jpg", "test3.jpg", "test4.jpg", "test5.webp"].map(
  (f) => path.join(SAMPLE_DIR, f)
);

// Expected rough CVA ranges (visual estimate, for sanity-checking)
const EXPECTED = {
  "test1.jpg":  { lo: 28, hi: 42, note: "phone / extreme forward head" },
  "test2.jpg":  { lo: 38, hi: 50, note: "desk / moderate forward head" },
  "test3.jpg":  { lo: 30, hi: 42, note: "laptop on lap / severe hunch" },
  "test4.jpg":  { lo: 28, hi: 40, note: "phone / extreme forward head" },
  "test5.webp": { lo: 48, hi: 60, note: "standing profile / mild-moderate" },
};

// ─── CVA helpers ─────────────────────────────────────────────────────────────

function calcCoordCva(tragus, shoulder, imgW, imgH) {
  const dxPx = Math.abs(tragus.x - shoulder.x) * imgW;
  const dyPx = (shoulder.y - tragus.y) * imgH;
  if (dxPx < 1e-6 && dyPx < 1e-6) return 0;
  if (dyPx <= 0) return 0;
  return +(Math.atan2(dyPx, dxPx || 0.001) * (180 / Math.PI)).toFixed(1);
}

function selectCva(aiCva, coordCva, deltaXNorm) {
  // If landmarks have good horizontal separation (≥20% of image width),
  // trust coordinate-based CVA.  Otherwise fall back to AI direct estimate.
  if (deltaXNorm >= 0.20) return { value: coordCva, source: "coord" };
  if (typeof aiCva === "number" && aiCva >= 20 && aiCva <= 85)
    return { value: aiCva, source: "ai" };
  return { value: coordCva, source: "coord-fallback" };
}

function classifyRisk(cva) {
  if (cva >= 55) return "정상";
  if (cva >= 50) return "주의";
  if (cva >= 45) return "경도거북목";
  return "고위험";
}

// ─── Image helpers ────────────────────────────────────────────────────────────

async function getImageDimensions(filePath) {
  const { default: sharp } = await import("sharp");
  const meta = await sharp(filePath).metadata();
  return { w: meta.width, h: meta.height };
}

function toDataUrl(filePath) {
  const buf = fs.readFileSync(filePath);
  const ext = path.extname(filePath).slice(1).toLowerCase();
  const mime =
    ext === "webp" ? "image/webp" : ext === "png" ? "image/png" : "image/jpeg";
  return `data:${mime};base64,${buf.toString("base64")}`;
}

// ─── Prompts ─────────────────────────────────────────────────────────────────

function buildPayload(imageDataUrl, imgW, imgH, promptVariant) {
  const schema = {
    type: "object",
    additionalProperties: false,
    properties: {
      side_photo_assessment: {
        type: "object",
        additionalProperties: false,
        properties: {
          tragus_point: pointSchema(),
          shoulder_or_c7_point: pointSchema(),
          cva_angle_degrees: { type: "number" },
          point_confidence: { type: "number" },
          measurement_basis: { type: "string" },
          posture_observations: { type: "array", items: { type: "string" } },
        },
        required: [
          "tragus_point", "shoulder_or_c7_point", "cva_angle_degrees",
          "point_confidence", "measurement_basis", "posture_observations",
        ],
      },
      posture_summary: { type: "string" },
      personalized_feedback: { type: "string" },
      recommended_actions: { type: "array", items: { type: "string" } },
      caution_note: { type: "string" },
    },
    required: [
      "side_photo_assessment", "posture_summary", "personalized_feedback",
      "recommended_actions", "caution_note",
    ],
  };

  const systemText = promptVariant === "improved"
    ? SYSTEM_IMPROVED
    : SYSTEM_CURRENT;

  return {
    model: MODEL,
    input: [
      { role: "system", content: [{ type: "input_text", text: systemText }] },
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: [
              "업로드된 사진에서 CVA를 측정해줘.",
              `이미지 해상도: ${imgW}×${imgH}px`,
              "옆모습 사진에서 tragus와 C7(또는 acromion) 기준점을 찾아 좌표를 반환해줘.",
              "기준점이 사람 밖에 있으면 안 되고, 전체 이미지 기준 정규화 좌표로 반환해줘.",
              "사진이 완전한 옆모습이 아니면 가장 합리적인 추정치를 주되, measurement_basis에 추정 한계를 적어줘.",
            ].join("\n"),
          },
          { type: "input_image", image_url: imageDataUrl, detail: "high" },
        ],
      },
    ],
    text: {
      format: { type: "json_schema", name: "posture_analysis", schema, strict: true },
    },
  };
}

function pointSchema() {
  return {
    type: "object", additionalProperties: false,
    properties: { x: { type: "number" }, y: { type: "number" }, label: { type: "string" } },
    required: ["x", "y", "label"],
  };
}

// ── Current prompt (before improvement) ──────────────────────────────────────
const SYSTEM_CURRENT = [
  "너는 한국어로 답하는 자세 분석 도우미다.",
  "반드시 side_photo_assessment 안에 업로드된 자세 사진 기준 tragus_point와 shoulder_or_c7_point를 정규화 좌표로 제공해라.",
  "정규화 좌표는 x, y를 0과 1 사이 숫자로 반환한다. x=0은 이미지 왼쪽 끝, x=1은 오른쪽 끝, y=0은 이미지 위 끝, y=1은 아래 끝이다.",
  "tragus_point는 보이는 귀의 외이도 입구 바로 앞 작은 연골 돌기(tragus) 중심으로 잡아라. 귀 전체 중앙이 아니라 외이도 바로 앞 작은 돌기를 정확히 찍어라.",
  "shoulder_or_c7_point는 가능하면 C7(목 뒤 가장 튀어나온 경추 7번 돌출부) 중심을 우선으로 잡고, C7가 가려졌으면 보이는 쪽 어깨 끝(acromion) 중심을 대신 사용해라. 사용한 기준점을 measurement_basis에 명시해라.",
  "두 점 모두 반드시 사람의 윤곽선 또는 인체 내부 위에 있어야 하며, 배경, 머리카락 바깥, 옷 바깥, 빈 공간을 찍으면 안 된다.",
  "좌표를 내기 전에 내부적으로 두 점이 실제 인체 위에 있는지, tragus가 shoulder_or_c7_point보다 위쪽(y값이 더 작음)에 있는지 다시 확인하고 틀리면 수정해라.",
  "CVA(두경부 전방 기울기 각도)는 다음과 같이 측정한다: shoulder_or_c7_point를 지나는 수평선과 shoulder_or_c7_point에서 tragus_point를 향하는 직선 사이의 각도. 이 각도를 cva_angle_degrees에 소수점 한 자리 숫자로 기입해라. 정상 CVA ≥ 55°이며 값이 작을수록 앞쪽으로 기울어진 거북목이다. CVA는 사진을 보고 두 기준점의 실제 픽셀 위치와 이미지 가로세로 비율을 감안해 직접 계산해라.",
  "가능하면 사진에서 측면 정렬을 판단하고, 정면에 가까워 측정이 불확실하면 measurement_basis와 posture_observations에 그 한계를 분명히 적어라.",
  "기준점이 가려졌거나 흐리면 억지로 확정하지 말고 point_confidence를 낮춰라.",
  "의학적 진단처럼 단정하지 말고 사진 기반 추정이라고 명시한다.",
  "반드시 JSON 스키마를 지켜라. 설명 텍스트를 JSON 밖에 쓰지 마라.",
].join(" ");

// ── Improved prompt ───────────────────────────────────────────────────────────
const SYSTEM_IMPROVED = [
  "너는 한국어로 답하는 자세 분석 도우미다.",
  "반드시 side_photo_assessment 안에 업로드된 자세 사진 기준 tragus_point와 shoulder_or_c7_point를 정규화 좌표로 제공해라.",
  "정규화 좌표는 x, y를 0과 1 사이 숫자로 반환한다. x=0은 이미지 왼쪽 끝, x=1은 오른쪽 끝, y=0은 이미지 위 끝, y=1은 아래 끝이다.",

  // Step-by-step landmark placement
  "【기준점 설정 절차 — 반드시 이 순서를 따라라】",

  "① 얼굴 방향 파악: 사진 속 사람이 오른쪽을 보는지 왼쪽을 보는지 먼저 확인한다.",

  "② tragus_point: 보이는 귀의 외이도 입구 바로 앞 작은 연골 돌기(tragus) 중심. 귀 전체 중앙이 아니라 외이도 바로 앞 돌기를 정확히 잡아라.",

  "③ shoulder_or_c7_point: 사람이 바라보는 방향의 정반대쪽(후방)에서 찾아라. " +
  "C7 우선 — C7(제7경추)은 목을 앞으로 숙이면 목 뒤에서 가장 먼저 튀어나오는 뼈 돌기로, 목과 등이 만나는 후면의 기준점이다. " +
  "C7이 보이지 않으면 acromion(어깨뼈의 가장 바깥쪽 끝점, 어깨 끝 가장 높은 지점) 사용. " +
  "사용한 기준점 종류를 measurement_basis에 반드시 명시해라.",

  "④ 방향 검증(필수): " +
  "사람이 오른쪽을 향하면 shoulder_or_c7_point.x 값이 tragus_point.x 값보다 반드시 작아야 한다(기준점이 귀보다 왼쪽). " +
  "사람이 왼쪽을 향하면 shoulder_or_c7_point.x 값이 tragus_point.x 값보다 반드시 커야 한다(기준점이 귀보다 오른쪽). " +
  "이 조건을 위반하면 기준점이 잘못된 것이므로 수정해라.",

  "⑤ 수평 거리 검증(필수): " +
  "|tragus_point.x − shoulder_or_c7_point.x|가 0.10 미만이면 기준점이 너무 앞쪽(머리 근처)에 있는 것이다. " +
  "C7/acromion은 실제로 귀보다 수평으로 10% 이상 후방에 위치하므로, 조건을 충족하지 못하면 기준점을 더 뒤쪽으로 이동해라.",

  "⑥ 높이 검증: tragus_point.y < shoulder_or_c7_point.y (귀가 어깨보다 위쪽)인지 확인하고 아니면 수정해라.",

  // CVA definition
  "CVA(두경부 전방 기울기 각도) 계산: shoulder_or_c7_point를 지나는 수평선과 shoulder_or_c7_point에서 tragus_point를 향하는 직선 사이의 각도. " +
  "이미지 해상도(가로×세로 픽셀)를 반드시 반영해 계산하고 cva_angle_degrees에 소수점 한 자리로 기입해라. " +
  "정상 CVA ≥ 55°, 고위험 CVA < 45°.",

  "두 점 모두 반드시 사람의 윤곽선 또는 인체 내부 위에 있어야 한다. 배경, 머리카락 바깥, 옷 바깥, 빈 공간에 찍으면 안 된다.",
  "기준점이 가려졌거나 흐리면 억지로 확정하지 말고 point_confidence를 낮춰라.",
  "의학적 진단처럼 단정하지 말고 사진 기반 추정이라고 명시한다.",
  "반드시 JSON 스키마를 지켜라. 설명 텍스트를 JSON 밖에 쓰지 마라.",
].join(" ");

// ─── API call ─────────────────────────────────────────────────────────────────

async function analyzeImage(filePath, promptVariant) {
  const { w, h } = await getImageDimensions(filePath);
  const dataUrl = toDataUrl(filePath);
  const payload = buildPayload(dataUrl, w, h, promptVariant);

  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${API_KEY}` },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(`API error ${res.status}: ${err?.error?.message}`);
  }

  const data = await res.json();
  const raw =
    data.output_text ||
    data.output?.flatMap((i) => i.content || [])?.find((c) => c.type === "output_text")?.text;

  const parsed = JSON.parse(raw);
  const a = parsed.side_photo_assessment;
  const tr = a.tragus_point;
  const sh = a.shoulder_or_c7_point;

  const aiCva = a.cva_angle_degrees;
  const coordCva = calcCoordCva(tr, sh, w, h);
  const deltaXNorm = Math.abs(tr.x - sh.x);
  const { value: finalCva, source } = selectCva(aiCva, coordCva, deltaXNorm);

  return {
    imgW: w, imgH: h, tragus: tr, shoulder: sh,
    aiCva, coordCva, finalCva, source,
    deltaXNorm,
    risk: classifyRisk(finalCva),
    confidence: Math.round(a.point_confidence * 100),
    basis: a.measurement_basis,
  };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

const variants = ["current", "improved"];

for (const variant of variants) {
  console.log(`\n${"═".repeat(76)}`);
  console.log(`  프롬프트: ${variant.toUpperCase()}  (model: ${MODEL})`);
  console.log(`${"═".repeat(76)}`);

  for (const sample of SAMPLES) {
    const name = path.basename(sample);
    const exp = EXPECTED[name];
    process.stdout.write(`▶ ${name} … `);
    try {
      const r = await analyzeImage(sample, variant);
      const inRange = r.finalCva >= exp.lo && r.finalCva <= exp.hi;
      const mark = inRange ? "✓" : "✗";
      console.log(`done`);
      console.log(`  ${r.imgW}×${r.imgH}  |  tragus(${r.tragus.x.toFixed(3)},${r.tragus.y.toFixed(3)})  shoulder(${r.shoulder.x.toFixed(3)},${r.shoulder.y.toFixed(3)})  ΔxNorm=${r.deltaXNorm.toFixed(3)}`);
      console.log(`  CVA: AI=${r.aiCva?.toFixed(1)??"—"}°  coord=${r.coordCva}°  → 최종=${r.finalCva}° [${r.source}]  ${mark}  (기대 ${exp.lo}–${exp.hi}°, ${exp.note})`);
      console.log(`  ${r.risk}  신뢰도${r.confidence}%  |  ${r.basis.slice(0,80)}`);
    } catch (e) {
      console.log(`ERROR: ${e.message}`);
    }
    console.log();
  }
}
