const form = document.getElementById("analysis-form");
const statusText = document.getElementById("statusText");
const resultEmpty = document.getElementById("resultEmpty");
const resultContent = document.getElementById("resultContent");
const submitButton = document.getElementById("submitButton");
const canvas = document.getElementById("sideCanvas");
const context = canvas.getContext("2d");
const photoPreviewCard = document.getElementById("photoPreviewCard");
const photoPreview = document.getElementById("photoPreview");

const cvaValue = document.getElementById("cvaValue");
const riskBadge = document.getElementById("riskBadge");
const painSummary = document.getElementById("painSummary");
const measurementBasis = document.getElementById("measurementBasis");
const postureSummary = document.getElementById("postureSummary");
const customFeedback = document.getElementById("customFeedback");
const actionList = document.getElementById("actionList");

const sliderConfigs = [
    { id: "height", unit: "cm" },
    { id: "deskHeight", unit: "cm" },
    { id: "chairHeight", unit: "cm" },
    { id: "phoneHours", unit: "시간" },
    { id: "studyHours", unit: "시간" },
    { id: "painLevel", unit: "점" }
];

for (const { id, unit } of sliderConfigs) {
    const input = document.getElementById(id);
    const output = document.getElementById(`${id}Output`);

    const renderValue = () => {
        output.value = `${input.value} ${unit}`;
        output.textContent = `${input.value} ${unit}`;
    };

    input.addEventListener("input", renderValue);
    renderValue();
}

document.getElementById("mainPhoto").addEventListener("change", async (event) => {
    const file = event.target.files?.[0];

    if (!file) {
        photoPreviewCard.classList.add("hidden");
        photoPreview.removeAttribute("src");
        return;
    }

    try {
        const dataUrl = await fileToDataUrl(file);
        photoPreview.src = dataUrl;
        photoPreviewCard.classList.remove("hidden");
    } catch (error) {
        console.error(error);
        setStatus("사진 미리보기를 불러오지 못했습니다.", "error");
    }
});

form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const formData = new FormData(form);
    const mainPhoto = formData.get("mainPhoto");

    if (!(mainPhoto instanceof File) || !mainPhoto.size) {
        setStatus("자세 사진을 선택하세요.", "error");
        return;
    }

    const numericInputs = ["height", "deskHeight", "chairHeight", "phoneHours", "studyHours", "painLevel"];
    for (const name of numericInputs) {
        const value = Number(formData.get(name));
        if (Number.isNaN(value)) {
            setStatus("수치 입력값을 확인하세요.", "error");
            return;
        }
    }

    submitButton.disabled = true;
    setStatus("사진을 준비하고 ChatGPT API에 분석을 요청하는 중입니다...", "loading");

    try {
        const mainPhotoUrl = await fileToDataUrl(mainPhoto);

        const payload = buildRequestPayload({
            model: String(formData.get("model") || "gpt-4.1-mini").trim(),
            profile: {
                heightCm: Number(formData.get("height")),
                deskHeightCm: Number(formData.get("deskHeight")),
                chairHeightCm: Number(formData.get("chairHeight")),
                smartphoneHoursPerDay: Number(formData.get("phoneHours")),
                studyHoursPerDay: Number(formData.get("studyHours")),
                neckPainLevel: Number(formData.get("painLevel"))
            },
            mainPhotoUrl
        });

        const apiKey = String(formData.get("apiKey") || "").trim();
        const analysis = await requestAnalysis(apiKey, payload);
        const normalized = normalizeAnalysis(analysis);

        renderResults(normalized, mainPhotoUrl);
        setStatus("분석이 완료되었습니다.", "done");
    } catch (error) {
        console.error(error);
        setStatus(error.message || "분석 중 오류가 발생했습니다.", "error");
    } finally {
        submitButton.disabled = false;
    }
});

function buildRequestPayload({ model, profile, mainPhotoUrl }) {
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
                    point_confidence: {
                        type: "number"
                    },
                    measurement_basis: {
                        type: "string"
                    },
                    posture_observations: {
                        type: "array",
                        items: {
                            type: "string"
                        }
                    }
                },
                required: [
                    "tragus_point",
                    "shoulder_or_c7_point",
                    "point_confidence",
                    "measurement_basis",
                    "posture_observations"
                ]
            },
            posture_summary: {
                type: "string"
            },
            personalized_feedback: {
                type: "string"
            },
            recommended_actions: {
                type: "array",
                items: {
                    type: "string"
                }
            },
            caution_note: {
                type: "string"
            }
        },
        required: [
            "side_photo_assessment",
            "posture_summary",
            "personalized_feedback",
            "recommended_actions",
            "caution_note"
        ]
    };

    return {
        model,
        input: [
            {
                role: "system",
                content: [
                    {
                        type: "input_text",
                        text: [
                            "너는 한국어로 답하는 자세 분석 도우미다.",
                            "반드시 side_photo_assessment 안에 업로드된 자세 사진 기준 tragus_point와 shoulder_or_c7_point를 정규화 좌표로 제공해라.",
                            "정규화 좌표는 x, y를 0과 1 사이 숫자로 반환한다.",
                            "측정 기준은 귀의 tragus와 C7 또는 어깨 기준점을 연결한 각도(CVA) 계산용이다.",
                            "가능하면 사진에서 측면 정렬을 판단하고, 정면에 가까워 측정이 불확실하면 measurement_basis와 posture_observations에 그 한계를 분명히 적어라.",
                            "의학적 진단처럼 단정하지 말고 사진 기반 추정이라고 명시한다.",
                            "반드시 JSON 스키마를 지켜라. 설명 텍스트를 JSON 밖에 쓰지 마라."
                        ].join(" ")
                    }
                ]
            },
            {
                role: "user",
                content: [
                    {
                        type: "input_text",
                        text: [
                            "다음 정보를 반영해서 자세를 분석해줘.",
                            `키: ${profile.heightCm}cm`,
                            `책상 높이: ${profile.deskHeightCm}cm`,
                            `의자 높이: ${profile.chairHeightCm}cm`,
                            `하루 스마트폰 사용시간: ${profile.smartphoneHoursPerDay}시간`,
                            `하루 공부 시간: ${profile.studyHoursPerDay}시간`,
                            `목 통증 정도: ${profile.neckPainLevel}/10`,
                            "업로드된 사진 한 장에서 자세를 관찰하고 CVA 측정이 가능하면 tragus와 shoulder 또는 C7 기준점을 찾아 좌표를 반환해줘.",
                            "사진이 완전한 옆모습이 아니면 가장 합리적인 추정치를 주되, measurement_basis에 추정 한계를 적고, 메인 사진과 생활 정보를 종합해서 posture_summary와 personalized_feedback, recommended_actions를 작성해줘."
                        ].join("\n")
                    },
                    {
                        type: "input_image",
                        image_url: mainPhotoUrl,
                        detail: "high"
                    }
                ]
            }
        ],
        text: {
            format: {
                type: "json_schema",
                name: "posture_analysis",
                schema,
                strict: true
            }
        }
    };
}

function pointSchema() {
    return {
        type: "object",
        additionalProperties: false,
        properties: {
            x: {
                type: "number"
            },
            y: {
                type: "number"
            },
            label: {
                type: "string"
            }
        },
        required: ["x", "y", "label"]
    };
}

async function requestAnalysis(apiKey, payload) {
    if (!apiKey) {
        throw new Error("OpenAI API Key를 입력하세요.");
    }

    const response = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${apiKey}`
        },
        body: JSON.stringify(payload)
    });

    if (!response.ok) {
        const errorData = await safeJson(response);
        const message = errorData?.error?.message || `API 호출 실패 (${response.status})`;
        throw new Error(message);
    }

    const responseData = await response.json();
    const rawText =
        responseData.output_text ||
        responseData.output?.flatMap((item) => item.content || [])
            ?.find((item) => item.type === "output_text")
            ?.text;

    if (!rawText) {
        throw new Error("API 응답에서 분석 결과를 읽지 못했습니다.");
    }

    try {
        return JSON.parse(rawText);
    } catch (error) {
        throw new Error("API가 예상한 JSON 형식으로 응답하지 않았습니다.");
    }
}

function normalizeAnalysis(analysis) {
    const assessment = analysis.side_photo_assessment;
    const tragus = clampPoint(assessment.tragus_point);
    const shoulder = clampPoint(assessment.shoulder_or_c7_point);
    const cva = calculateCva(tragus, shoulder);
    const risk = classifyRisk(cva);

    return {
        cva,
        risk,
        tragus,
        shoulder,
        pointConfidence: Number(assessment.point_confidence) || 0,
        measurementBasis: assessment.measurement_basis || "",
        postureSummary: analysis.posture_summary || "",
        personalizedFeedback: analysis.personalized_feedback || "",
        recommendedActions: Array.isArray(analysis.recommended_actions) ? analysis.recommended_actions : [],
        cautionNote: analysis.caution_note || "",
        postureObservations: Array.isArray(assessment.posture_observations) ? assessment.posture_observations : []
    };
}

function clampPoint(point) {
    return {
        x: clamp(Number(point.x), 0, 1),
        y: clamp(Number(point.y), 0, 1),
        label: String(point.label || "기준점")
    };
}

function clamp(value, min, max) {
    if (!Number.isFinite(value)) {
        return min;
    }

    return Math.min(Math.max(value, min), max);
}

function calculateCva(tragus, shoulder) {
    const deltaX = Math.abs(tragus.x - shoulder.x);
    const deltaY = Math.abs(tragus.y - shoulder.y);

    if (deltaX === 0 && deltaY === 0) {
        return 0;
    }

    const radians = Math.atan2(deltaY, deltaX || 0.0001);
    return Number((radians * (180 / Math.PI)).toFixed(1));
}

function classifyRisk(cva) {
    if (cva >= 55) {
        return { label: "정상", color: "var(--ok)" };
    }

    if (cva >= 50) {
        return { label: "주의", color: "var(--warning)" };
    }

    if (cva >= 45) {
        return { label: "경도 거북목", color: "#c9671e" };
    }

    return { label: "고위험", color: "var(--danger)" };
}

async function renderResults(result, photoUrl) {
    resultEmpty.classList.add("hidden");
    resultContent.classList.remove("hidden");

    cvaValue.textContent = `${result.cva.toFixed(1)}°`;
    riskBadge.textContent = result.risk.label;
    riskBadge.style.background = result.risk.color;
    painSummary.textContent = `${Math.round(result.pointConfidence * 100)}% 신뢰 추정`;

    measurementBasis.textContent = [
        result.measurementBasis,
        `계산식: 어깨 또는 C7 기준점과 귀의 tragus를 연결한 선과 수평선의 각도(CVA) = ${result.cva.toFixed(1)}°`,
        `위험도 기준 적용: 55도 이상 정상, 50도 이상 주의, 45도 이상 경도 거북목, 45도 미만 고위험.`
    ].join(" ");

    postureSummary.textContent = [result.postureSummary, ...result.postureObservations].join(" ");
    customFeedback.textContent = [result.personalizedFeedback, result.cautionNote].join(" ");

    actionList.innerHTML = "";
    for (const action of result.recommendedActions) {
        const item = document.createElement("li");
        item.textContent = action;
        actionList.appendChild(item);
    }

    await drawAnnotatedImage(photoUrl, result.tragus, result.shoulder, result.cva);
}

async function drawAnnotatedImage(sidePhotoUrl, tragus, shoulder, cva) {
    const image = await loadImage(sidePhotoUrl);
    canvas.width = image.width;
    canvas.height = image.height;
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, image.width, image.height);

    const tragusPoint = {
        x: tragus.x * canvas.width,
        y: tragus.y * canvas.height
    };
    const shoulderPoint = {
        x: shoulder.x * canvas.width,
        y: shoulder.y * canvas.height
    };

    context.strokeStyle = "#c46f2a";
    context.lineWidth = Math.max(3, canvas.width / 280);
    context.beginPath();
    context.moveTo(shoulderPoint.x, shoulderPoint.y);
    context.lineTo(tragusPoint.x, tragusPoint.y);
    context.stroke();

    context.strokeStyle = "#3a7d44";
    context.beginPath();
    context.moveTo(shoulderPoint.x, shoulderPoint.y);
    context.lineTo(Math.min(canvas.width - 16, shoulderPoint.x + canvas.width * 0.2), shoulderPoint.y);
    context.stroke();

    drawPoint(tragusPoint, tragus.label, "#a93b2f");
    drawPoint(shoulderPoint, shoulder.label, "#274690");

    context.fillStyle = "rgba(44, 36, 29, 0.85)";
    context.font = `${Math.max(18, canvas.width / 36)}px Segoe UI`;
    context.fillText(`CVA ${cva.toFixed(1)}°`, 24, 40);
}

function drawPoint(point, label, color) {
    context.fillStyle = color;
    context.beginPath();
    context.arc(point.x, point.y, Math.max(6, canvas.width / 130), 0, Math.PI * 2);
    context.fill();

    context.fillStyle = "rgba(44, 36, 29, 0.88)";
    context.font = `${Math.max(16, canvas.width / 48)}px Segoe UI`;
    context.fillText(label, point.x + 14, Math.max(24, point.y - 12));
}

function loadImage(source) {
    return new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => reject(new Error("이미지를 불러오지 못했습니다."));
        image.src = source;
    });
}

function fileToDataUrl(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result));
        reader.onerror = () => reject(new Error("이미지를 읽는 중 오류가 발생했습니다."));
        reader.readAsDataURL(file);
    });
}

async function safeJson(response) {
    try {
        return await response.json();
    } catch {
        return null;
    }
}

function setStatus(message, tone) {
    statusText.textContent = message;
    statusText.classList.remove("status-error", "status-loading");

    if (tone === "error") {
        statusText.classList.add("status-error");
    }

    if (tone === "loading") {
        statusText.classList.add("status-loading");
    }
}