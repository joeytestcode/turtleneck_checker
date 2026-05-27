$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$envFile = Join-Path $PSScriptRoot '..\webapp_sample\.env'
$apiKey = (Get-Content $envFile -Raw).Trim()
if (-not $apiKey) {
  throw 'Missing OPENAI_API_KEY in webapp_sample/.env'
}

$env:OPENAI_API_KEY = $apiKey

function Get-CvaSchema {
  return @{
    type = 'object'
    additionalProperties = $false
    properties = @{
      side_photo_assessment = @{
        type = 'object'
        additionalProperties = $false
        properties = @{
          tragus_point = @{
            type = 'object'
            additionalProperties = $false
            properties = @{ x = @{ type = 'number' }; y = @{ type = 'number' }; label = @{ type = 'string' } }
            required = @('x', 'y', 'label')
          }
          shoulder_or_c7_point = @{
            type = 'object'
            additionalProperties = $false
            properties = @{ x = @{ type = 'number' }; y = @{ type = 'number' }; label = @{ type = 'string' } }
            required = @('x', 'y', 'label')
          }
          point_confidence = @{ type = 'number' }
          measurement_basis = @{ type = 'string' }
          posture_observations = @{ type = 'array'; items = @{ type = 'string' } }
        }
        required = @('tragus_point', 'shoulder_or_c7_point', 'point_confidence', 'measurement_basis', 'posture_observations')
      }
      posture_summary = @{ type = 'string' }
      personalized_feedback = @{ type = 'string' }
      recommended_actions = @{ type = 'array'; items = @{ type = 'string' } }
      caution_note = @{ type = 'string' }
    }
    required = @('side_photo_assessment', 'posture_summary', 'personalized_feedback', 'recommended_actions', 'caution_note')
  }
}

function Get-SystemPrompt {
  return @(
    '너는 한국어로 답하는 자세 분석 도우미다.',
    '반드시 side_photo_assessment 안에 업로드된 자세 사진 기준 tragus_point와 shoulder_or_c7_point를 정규화 좌표로 제공해라.',
    '정규화 좌표는 x, y를 0과 1 사이 숫자로 반환한다.',
    'CVA는 참고 이미지와 동일하게 spinous process of C7 점을 지나는 수평선과, C7에서 귀의 tragus를 잇는 선 사이의 예각이다.',
    'tragus_point는 보이는 귀의 외이도 입구 바로 앞 작은 연골 돌기 부근 중심, 즉 귀 중앙에 가장 가까운 점으로 잡아라.',
    'shoulder_or_c7_point는 이름과 다르게 원칙적으로 C7 극돌기 중심을 반환해야 한다.',
    'C7이 보이면 어깨(acromion)를 사용하지 말고 반드시 C7을 사용해라.',
    '정말로 C7이 머리카락, 옷깃, 촬영 각도 때문에 식별되지 않을 때만 목 뒤 하단과 어깨선이 만나는 posterior neck base를 제한적 대체점으로 사용해라.',
    '어깨(acromion)는 CVA 기준점으로 쓰지 말고, posterior neck base 위치를 추정할 때 보조 윤곽선으로만 참고해라.',
    'measurement_basis에는 C7을 사용했는지, 아니면 C7이 가려져 posterior neck base를 대체 사용했는지를 반드시 명시해라.',
    '두 점 모두 반드시 사람의 윤곽선 또는 인체 내부 위에 있어야 하며, 배경, 머리카락 바깥, 옷 바깥, 빈 공간을 찍으면 안 된다.',
    '좌표를 내기 전에 내부적으로 두 점이 실제 인체 위에 있는지, tragus가 shoulder_or_c7_point보다 위쪽에 있는지 다시 확인하고 틀리면 수정해라.',
    '가능하면 사진에서 측면 정렬을 판단하고, 정면에 가까워 측정이 불확실하면 measurement_basis와 posture_observations에 그 한계를 분명히 적어라.',
    '기준점이 가려졌거나 흐리면 억지로 확정하지 말고 point_confidence를 낮춰라.',
    '의학적 진단처럼 단정하지 말고 사진 기반 추정이라고 명시한다.',
    '반드시 JSON 스키마를 지켜라. 설명 텍스트를 JSON 밖에 쓰지 마라.'
  ) -join ' '
}

function Get-UserPrompt {
  return @(
    '다음 정보를 반영해서 자세를 분석해줘.',
    '키: 170cm',
    '책상 높이: 72cm',
    '의자 높이: 43cm',
    '하루 스마트폰 사용시간: 4.5시간',
    '하루 공부 시간: 6.0시간',
    '목 통증 정도: 3/10',
    '업로드된 사진 한 장에서 자세를 관찰하고 CVA 측정이 가능하면 tragus와 C7 기준점을 찾아 좌표를 반환해줘.',
    'CVA는 C7 점을 지나는 수평선과 C7-tragus 선 사이 각도로 계산하므로, 원칙적으로 C7 극돌기 중심을 찾아줘.',
    '귀 기준점은 귀 윤곽의 중앙이 아니라 tragus에 최대한 가깝게, C7 기준점은 목 뒤 하단의 C7 돌출 중심에 가깝게 잡아줘.',
    'C7이 정말 보이지 않을 때만 목 뒤 하단과 어깨선이 만나는 posterior neck base를 대체점으로 사용하고, 그 사실을 measurement_basis에 분명히 적어줘.',
    '특히 옷으로 어깨가 가려지거나 팔이 앞으로 나와 있는 사진에서는 어깨 끝점을 직접 기준점으로 쓰지 말고 목 뒤 하단 기준을 우선 추정해줘.',
    '기준점이 사람 밖에 있으면 안 되고, 사람이 프레임 한쪽에 치우쳐 있어도 전체 이미지 기준 정규화 좌표로 반환해줘.',
    '사진이 완전한 옆모습이 아니면 가장 합리적인 추정치를 주되, measurement_basis에 추정 한계를 적고, 메인 사진과 생활 정보를 종합해서 posture_summary와 personalized_feedback, recommended_actions를 작성해줘.'
  ) -join "`n"
}

function Get-RefinementPrompt($result) {
  return @(
    '이전 기준점 후보를 다시 검토해서 더 정확한 귀 중심과 C7 중심을 찾아줘.',
    "이전 tragus 후보: x=$($result.tragus.x), y=$($result.tragus.y).",
    "이전 shoulder/C7 후보: x=$($result.reference.x), y=$($result.reference.y).",
    "이전 계산 CVA는 $($result.cva)도로, 기준점이 지나치게 수직으로 잡혔을 가능성이 있으면 다시 조정해줘.",
    '이번에는 참고 이미지의 정의처럼 C7을 지나는 수평선과 C7-tragus 선의 각도가 되도록, 가능하면 반드시 C7 극돌기 중심을 찾아줘.',
    'C7이 가려져 있다면 어깨 끝이 아니라 목 뒤 하단과 어깨선이 만나는 posterior neck base를 대체점으로 써줘.',
    '특히 CVA가 비정상적으로 크게 나오지 않도록, 기준점이 귀 바로 아래가 아니라 목 뒤 하단의 posterior cervical landmark인지 다시 확인해줘.',
    '이전 좌표는 사람 밖이거나 기준점 중심에서 벗어났을 가능성이 있으니, 반드시 사람 내부의 해부학적 중심점으로 다시 잡아줘.',
    '재검토 후에도 확실하지 않으면 point_confidence를 낮추고 measurement_basis에 불확실성을 적어줘.'
  ) -join ' '
}

function Get-OutputText($response) {
  if ($response.output_text) {
    return $response.output_text
  }

  foreach ($item in $response.output) {
    foreach ($content in $item.content) {
      if ($content.type -eq 'output_text') {
        return $content.text
      }
    }
  }

  throw 'No output_text found in response.'
}

function Test-SuspiciousCvaRange($result) {
  $deltaX = [math]::Abs([double]$result.tragus.x - [double]$result.reference.x)
  $deltaY = [math]::Abs([double]$result.tragus.y - [double]$result.reference.y)
  return $result.cva -gt 65 -or ($result.cva -gt 60 -and $deltaX -lt ($deltaY * 0.45))
}

function Invoke-Analysis($relativePath, $refinementHint) {
  $fullPath = Join-Path $PSScriptRoot ('..\\' + $relativePath)
  $guidePath = Join-Path $PSScriptRoot '..\\webapp_sample\\image.png'
  $bytes = [System.IO.File]::ReadAllBytes($fullPath)
  $guideBytes = [System.IO.File]::ReadAllBytes($guidePath)
  $mime = switch ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()) {
    '.jpeg' { 'image/jpeg' }
    '.jpg' { 'image/jpeg' }
    '.webp' { 'image/webp' }
    default { 'application/octet-stream' }
  }

  $userPrompt = Get-UserPrompt
  if ($refinementHint) {
    $userPrompt = $userPrompt + "`n" + $refinementHint
  }

  $payload = @{
    model = 'gpt-4.1'
    temperature = 0
    input = @(
      @{ role = 'system'; content = @(@{ type = 'input_text'; text = (Get-SystemPrompt) }) },
      @{
        role = 'user'
        content = @(
          @{ type = 'input_text'; text = $userPrompt },
          @{ type = 'input_image'; image_url = "data:image/png;base64,$([Convert]::ToBase64String($guideBytes))"; detail = 'high' },
          @{ type = 'input_image'; image_url = "data:$mime;base64,$([Convert]::ToBase64String($bytes))"; detail = 'high' }
        )
      }
    )
    text = @{ format = @{ type = 'json_schema'; name = 'posture_analysis'; schema = (Get-CvaSchema); strict = $true } }
  }

  $jsonBody = $payload | ConvertTo-Json -Depth 30
  $client = [System.Net.Http.HttpClient]::new()
  $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $env:OPENAI_API_KEY)
  $content = [System.Net.Http.StringContent]::new($jsonBody, [System.Text.Encoding]::UTF8, 'application/json')
  $httpResponse = $client.PostAsync('https://api.openai.com/v1/responses', $content).GetAwaiter().GetResult()
  $rawResponse = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  if (-not $httpResponse.IsSuccessStatusCode) {
    throw $rawResponse
  }

  return (Get-OutputText ($rawResponse | ConvertFrom-Json)) | ConvertFrom-Json
}

function Invoke-CvaCheck($relativePath) {
  $analysis = Invoke-Analysis $relativePath $null
  $tragus = $analysis.side_photo_assessment.tragus_point
  $reference = $analysis.side_photo_assessment.shoulder_or_c7_point
  $deltaX = [math]::Abs([double]$tragus.x - [double]$reference.x)
  $deltaY = [math]::Abs([double]$tragus.y - [double]$reference.y)
  $cva = [math]::Round(([math]::Atan2($deltaY, [math]::Max($deltaX, 0.0001)) * 180 / [math]::PI), 1)
  $result = [ordered]@{
    file = [System.IO.Path]::GetFileName($relativePath)
    cva = $cva
    confidence = [math]::Round([double]$analysis.side_photo_assessment.point_confidence, 3)
    basis = $analysis.side_photo_assessment.measurement_basis
    tragus = [ordered]@{ x = [double]$tragus.x; y = [double]$tragus.y; label = [string]$tragus.label }
    reference = [ordered]@{ x = [double]$reference.x; y = [double]$reference.y; label = [string]$reference.label }
  }

  if (Test-SuspiciousCvaRange $result) {
    $analysis = Invoke-Analysis $relativePath (Get-RefinementPrompt $result)
    $tragus = $analysis.side_photo_assessment.tragus_point
    $reference = $analysis.side_photo_assessment.shoulder_or_c7_point
    $deltaX = [math]::Abs([double]$tragus.x - [double]$reference.x)
    $deltaY = [math]::Abs([double]$tragus.y - [double]$reference.y)
    $cva = [math]::Round(([math]::Atan2($deltaY, [math]::Max($deltaX, 0.0001)) * 180 / [math]::PI), 1)
    $result = [ordered]@{
      file = [System.IO.Path]::GetFileName($relativePath)
      cva = $cva
      confidence = [math]::Round([double]$analysis.side_photo_assessment.point_confidence, 3)
      basis = $analysis.side_photo_assessment.measurement_basis
      tragus = [ordered]@{ x = [double]$tragus.x; y = [double]$tragus.y; label = [string]$tragus.label }
      reference = [ordered]@{ x = [double]$reference.x; y = [double]$reference.y; label = [string]$reference.label }
    }
  }

  [pscustomobject]@{
    file = $result.file
    cva = $result.cva
    confidence = $result.confidence
    basis = $result.basis
    tragus = "x=$([math]::Round($result.tragus.x, 3)), y=$([math]::Round($result.tragus.y, 3)), label=$($result.tragus.label)"
    reference = "x=$([math]::Round($result.reference.x, 3)), y=$([math]::Round($result.reference.y, 3)), label=$($result.reference.label)"
  }
}

$files = @('webapp_sample\test1.jpeg', 'webapp_sample\test2.webp', 'webapp_sample\test3.jpeg')
$results = foreach ($file in $files) { Invoke-CvaCheck $file }
$results | Format-List | Out-String