import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

const _hardcodedApiKey = '';
const _bundledOpenAiApiKey = String.fromEnvironment('OPENAI_API_KEY');
const _bundledLegacyChatGptApiKey = String.fromEnvironment('CHATGPT_API_KEY');
const _apiKeyPreferenceKey = 'openai_api_key';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFBB5A1B);

    return MaterialApp(
      title: 'NoTurtleAnyM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: const Color(0xFFF7F1E8),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(28)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: seed, width: 1.4),
          ),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: seed,
          inactiveTrackColor: Color(0xFFEAD8C7),
          thumbColor: seed,
        ),
      ),
      home: const PostureCheckerScreen(),
    );
  }
}

class PostureCheckerScreen extends StatefulWidget {
  const PostureCheckerScreen({super.key});

  @override
  State<PostureCheckerScreen> createState() => _PostureCheckerScreenState();
}

class _PostureCheckerScreenState extends State<PostureCheckerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _apiKeyController = TextEditingController();
  final _nameController = TextEditingController();
  final _imagePicker = ImagePicker();
  final _historyDatabase = AnalysisHistoryDatabase.instance;

  String _model = 'gpt-4.1-mini';
  double _height = 170;
  double _deskHeight = 72;
  double _chairHeight = 43;
  double _phoneHours = 4.5;
  double _studyHours = 6;
  double _painLevel = 3;
  Uint8List? _selectedImageBytes;
  ui.Image? _decodedImage;
  String _statusMessage = '사진과 생활 습관 정보를 입력한 뒤 분석을 시작하세요.';
  StatusTone _statusTone = StatusTone.idle;
  bool _isSubmitting = false;
  bool _isHistoryLoading = false;
  PostureAnalysisResult? _result;
  List<String> _savedInspectors = const [];
  String? _selectedHistoryName;
  List<AnalysisHistoryEntry> _historyEntries = const [];

  @override
  void initState() {
    super.initState();
    _loadSavedApiKey();
    _loadInspectorNames();
  }

  String get _bundledApiKey {
    final hardcoded = _hardcodedApiKey.trim();
    if (hardcoded.isNotEmpty) {
      return hardcoded;
    }

    final primary = _bundledOpenAiApiKey.trim();
    if (primary.isNotEmpty) {
      return primary;
    }

    return _bundledLegacyChatGptApiKey.trim();
  }

  bool get _hasBundledApiKey => _bundledApiKey.isNotEmpty;

  bool get _hasSavedApiKey => _apiKeyController.text.trim().isNotEmpty;

  String get _resolvedApiKey {
    final typedApiKey = _apiKeyController.text.trim();
    if (typedApiKey.isNotEmpty) {
      return typedApiKey;
    }

    return _bundledApiKey;
  }

  Future<void> _loadSavedApiKey() async {
    final preferences = await SharedPreferences.getInstance();
    final savedApiKey = preferences.getString(_apiKeyPreferenceKey)?.trim() ?? '';
    if (savedApiKey.isEmpty || !mounted) {
      return;
    }

    setState(() {
      _apiKeyController.text = savedApiKey;
    });
  }

  Future<void> _loadInspectorNames() async {
    List<String> inspectorNames;
    try {
      inspectorNames = await _historyDatabase.fetchInspectorNames();
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedInspectors = const [];
        _selectedHistoryName = null;
        _historyEntries = const [];
      });
      return;
    }

    if (!mounted) {
      return;
    }

    final selectedName = inspectorNames.contains(_selectedHistoryName)
        ? _selectedHistoryName
        : inspectorNames.isNotEmpty
            ? inspectorNames.first
            : null;

    setState(() {
      _savedInspectors = inspectorNames;
      _selectedHistoryName = selectedName;
    });

    if (selectedName != null) {
      await _loadHistoryForName(selectedName);
    }
  }

  Future<void> _loadHistoryForName(String name) async {
    setState(() {
      _isHistoryLoading = true;
      _selectedHistoryName = name;
    });

    List<AnalysisHistoryEntry> entries;
    try {
      entries = await _historyDatabase.fetchEntriesForInspector(name);
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _historyEntries = const [];
        _isHistoryLoading = false;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _historyEntries = entries;
      _isHistoryLoading = false;
    });
  }

  Future<void> _saveApiKey(String value) async {
    final preferences = await SharedPreferences.getInstance();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await preferences.remove(_apiKeyPreferenceKey);
      return;
    }

    await preferences.setString(_apiKeyPreferenceKey, trimmed);
  }

  Future<String?> _pickApiKeyFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['key', 'txt'],
      allowMultiple: false,
      withData: true,
      dialogTitle: 'api.key 파일 선택',
    );

    final file = result?.files.singleOrNull;
    if (file == null) {
      return null;
    }

    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('선택한 파일을 읽지 못했습니다. api.key 파일 내용을 확인하세요.');
    }

    final key = utf8.decode(bytes, allowMalformed: true).trim();
    if (key.isEmpty) {
      throw Exception('api.key 파일이 비어 있습니다. 파일에 API Key만 넣어 주세요.');
    }

    return key;
  }

  Future<void> _openAiSettingsDialog() async {
    final apiKeyController = TextEditingController(text: _apiKeyController.text.trim());
    var selectedModel = _model;
    final theme = Theme.of(context);
    String? dialogMessage;
    var dialogMessageTone = StatusTone.idle;

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFFFFFCF8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              title: const Text('AI 설정'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'API Key는 이 기기에 저장되며, 다음 실행 때도 그대로 유지됩니다.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF6B5D51),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: apiKeyController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'OpenAI API Key',
                        hintText: 'sk-...',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            final fileApiKey = await _pickApiKeyFromFile();
                            if (fileApiKey == null) {
                              return;
                            }

                            setDialogState(() {
                              apiKeyController.text = fileApiKey;
                              dialogMessage = 'api.key 파일에서 API Key를 불러왔습니다.';
                              dialogMessageTone = StatusTone.done;
                            });
                          } catch (error) {
                            setDialogState(() {
                              dialogMessage = error.toString().replaceFirst('Exception: ', '');
                              dialogMessageTone = StatusTone.error;
                            });
                          }
                        },
                        icon: const Icon(Icons.file_open_outlined),
                        label: const Text('api.key 파일에서 불러오기'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'api.key 파일에는 API Key 문자열만 한 줄로 저장해 두면 됩니다.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF7A5A44),
                        height: 1.5,
                      ),
                    ),
                    if (dialogMessage != null) ...[
                      const SizedBox(height: 12),
                      _StatusPill(
                        message: dialogMessage!,
                        tone: dialogMessageTone,
                      ),
                    ],
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: selectedModel,
                      decoration: const InputDecoration(
                        labelText: 'GPT 모델',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'gpt-4.1-mini',
                          child: Text('GPT-4.1 mini'),
                        ),
                        DropdownMenuItem(
                          value: 'gpt-4.1',
                          child: Text('GPT-4.1'),
                        ),
                        DropdownMenuItem(
                          value: 'gpt-4o',
                          child: Text('GPT-4o'),
                        ),
                        DropdownMenuItem(
                          value: 'gpt-4o-mini',
                          child: Text('GPT-4o mini'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() {
                            selectedModel = value;
                          });
                        }
                      },
                    ),
                    if (_hasBundledApiKey) ...[
                      const SizedBox(height: 14),
                      const Text(
                        '저장된 키가 비어 있으면 앱 기본 키를 사용합니다.',
                        style: TextStyle(
                          color: Color(0xFF7A5A44),
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('저장'),
                ),
              ],
            );
          },
        );
      },
    );

    if (shouldSave == true && mounted) {
      final trimmedApiKey = apiKeyController.text.trim();
      await _saveApiKey(trimmedApiKey);
      setState(() {
        _apiKeyController.text = trimmedApiKey;
        _model = selectedModel;
        _statusMessage = trimmedApiKey.isNotEmpty
            ? 'AI 설정이 저장되었습니다.'
            : '저장된 API 키를 지우고 기본 설정으로 전환했습니다.';
        _statusTone = StatusTone.idle;
      });
    }

    apiKeyController.dispose();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _nameController.dispose();
    super.dispose();      
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final file = await _imagePicker.pickImage(
        source: source,
        imageQuality: 95,
      );

      if (file == null) {
        return;
      }

      final bytes = await file.readAsBytes();
      final decoded = await decodeUiImage(bytes);

      if (!mounted) {
        return;
      }

      setState(() {
        _selectedImageBytes = bytes;
        _decodedImage = decoded;
        _statusMessage = source == ImageSource.camera
            ? '촬영한 사진이 준비되었습니다. 분석을 시작할 수 있습니다.'
            : '선택한 사진이 준비되었습니다. 분석을 시작할 수 있습니다.';
        _statusTone = StatusTone.idle;
        _result = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = '카메라 또는 사진 접근에 실패했습니다. 권한 설정을 확인하세요.';
        _statusTone = StatusTone.error;
      });
    }
  }

  Future<void> _openCameraWithGuide() async {
    final shouldCapture = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => const _CaptureGuideSheet(),
    );

    if (shouldCapture == true && mounted) {
      await _pickImage(ImageSource.camera);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_resolvedApiKey.isEmpty) {
      setState(() {
        _statusMessage = 'AI 설정에서 OpenAI API Key를 먼저 입력하세요.';
        _statusTone = StatusTone.error;
      });
      return;
    }

    final inspectorName = _nameController.text.trim();
    if (inspectorName.isEmpty) {
      setState(() {
        _statusMessage = '검사자 이름을 먼저 입력하세요.';
        _statusTone = StatusTone.error;
      });
      return;
    }

    final imageBytes = _selectedImageBytes;
    if (imageBytes == null) {
      setState(() {
        _statusMessage = '자세 사진을 먼저 선택하세요.';
        _statusTone = StatusTone.error;
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _statusMessage = '사진을 준비하고 OpenAI에 분석을 요청하는 중입니다...';
      _statusTone = StatusTone.loading;
    });

    try {
      final imageDataUrl = imageBytesToDataUrl(imageBytes);
      final payload = buildRequestPayload(
        model: _model,
        profile: UserProfile(
          heightCm: _height,
          deskHeightCm: _deskHeight,
          chairHeightCm: _chairHeight,
          smartphoneHoursPerDay: _phoneHours,
          studyHoursPerDay: _studyHours,
          neckPainLevel: _painLevel,
        ),
        mainPhotoUrl: imageDataUrl,
      );

      final rawAnalysis = await requestAnalysis(
        apiKey: _resolvedApiKey,
        payload: payload,
      );
      var normalized = normalizeAnalysis(rawAnalysis);

      if (shouldRetryLandmarkDetection(normalized)) {
        if (!mounted) {
          return;
        }

        setState(() {
          _statusMessage = '기준점이 불안정해 보여 귀와 어깨 중심 좌표를 다시 확인하는 중입니다...';
          _statusTone = StatusTone.loading;
        });

        final refinedPayload = buildRequestPayload(
          model: _model,
          profile: UserProfile(
            heightCm: _height,
            deskHeightCm: _deskHeight,
            chairHeightCm: _chairHeight,
            smartphoneHoursPerDay: _phoneHours,
            studyHoursPerDay: _studyHours,
            neckPainLevel: _painLevel,
          ),
          mainPhotoUrl: imageDataUrl,
          refinementHint: buildLandmarkRefinementHint(normalized),
        );
        final refinedAnalysis = await requestAnalysis(
          apiKey: _resolvedApiKey,
          payload: refinedPayload,
        );
        final refinedNormalized = normalizeAnalysis(refinedAnalysis);
        if (isLandmarkDetectionBetter(current: normalized, candidate: refinedNormalized)) {
          normalized = refinedNormalized;
        }
      }

      if (!mounted) {
        return;
      }

      var historySaveFailed = false;
      List<String> inspectorNames = _savedInspectors;
      List<AnalysisHistoryEntry> historyEntries = _historyEntries;

      try {
        await _historyDatabase.insertEntry(
          AnalysisHistoryEntry.create(
            inspectorName: inspectorName,
            analyzedAt: DateTime.now(),
            model: _model,
            cva: normalized.cva,
            riskLabel: normalized.risk.label,
            pointConfidence: normalized.pointConfidence,
            postureSummary: normalized.postureSummary,
            personalizedFeedback: normalized.personalizedFeedback,
            measurementBasis: normalized.measurementBasis,
            cautionNote: normalized.cautionNote,
            postureObservations: normalized.postureObservations,
            recommendedActions: normalized.recommendedActions,
            photoBase64: base64Encode(imageBytes),
          ),
        );

        inspectorNames = await _historyDatabase.fetchInspectorNames();
        historyEntries = await _historyDatabase.fetchEntriesForInspector(inspectorName);
      } catch (_) {
        historySaveFailed = true;
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _result = normalized;
        _savedInspectors = inspectorNames;
        _selectedHistoryName = inspectorName;
        _historyEntries = historyEntries;
        _statusMessage = historySaveFailed
            ? '분석은 완료되었지만 검사 기록 저장에는 실패했습니다.'
            : '분석이 완료되었습니다.';
        _statusTone = historySaveFailed ? StatusTone.error : StatusTone.done;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = error.toString().replaceFirst('Exception: ', '');
        _statusTone = StatusTone.error;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF9F2E9), Color(0xFFF2E4D5), Color(0xFFF7F1E8)],
          ),
        ),
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _HeroCard(),
                      const SizedBox(height: 18),
                      _StatusPill(message: _statusMessage, tone: _statusTone),
                      const SizedBox(height: 18),
                      Card(
                        color: const Color(0xFFFFFCF8),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: _SectionCard(
                            title: 'AI 설정',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF4EA),
                                    borderRadius: BorderRadius.circular(18),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '현재 모델: $_model',
                                        style: const TextStyle(
                                          color: Color(0xFF7A5A44),
                                        ),
                                      ),
                                      if (!_hasSavedApiKey && !_hasBundledApiKey) ...[
                                        const SizedBox(height: 8),
                                        const Text(
                                          'API Key를 입력해야 분석을 진행할 수 있습니다.',
                                          style: TextStyle(
                                            color: Color(0xFFA13F31),
                                            fontWeight: FontWeight.w700,
                                            height: 1.5,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: _isSubmitting ? null : _openAiSettingsDialog,
                                    icon: const Icon(Icons.tune_rounded),
                                    label: const Text('AI 설정 열기'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Card(
                        color: const Color(0xFFFFFCF8),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '입력 정보',
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _SectionCard(
                                  title: '검사자 정보',
                                  description: '이름별로 검사 기록을 저장하고, 아래 기록 섹션에서 개인별 이력을 다시 확인할 수 있습니다.',
                                  child: TextFormField(
                                    controller: _nameController,
                                    textInputAction: TextInputAction.done,
                                    decoration: const InputDecoration(
                                      labelText: '검사자 이름',
                                      hintText: '예: 홍길동',
                                      prefixIcon: Icon(Icons.person_outline),
                                    ),
                                    validator: (value) {
                                      if (value == null || value.trim().isEmpty) {
                                        return '검사자 이름을 입력하세요.';
                                      }
                                      return null;
                                    },
                                  ),
                                ),
                                const SizedBox(height: 20),
                                _SectionCard(
                                  title: '자세 사진',
                                  description: '카메라로 바로 촬영하거나 갤러리에서 옆모습 사진을 선택하면 미리보기가 표시됩니다.',
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 12,
                                        runSpacing: 12,
                                        children: [
                                          FilledButton.icon(
                                            onPressed: _isSubmitting
                                                ? null
                                                : _openCameraWithGuide,
                                            icon: const Icon(Icons.photo_camera_outlined),
                                            label: Text(
                                              _selectedImageBytes == null
                                                  ? '카메라로 촬영'
                                                  : '다시 촬영',
                                            ),
                                          ),
                                          OutlinedButton.icon(
                                            onPressed: _isSubmitting
                                                ? null
                                                : () => _pickImage(ImageSource.gallery),
                                            icon: const Icon(Icons.photo_library_outlined),
                                            label: const Text('앨범에서 선택'),
                                          ),
                                        ],
                                      ),
                                      if (_selectedImageBytes != null) ...[
                                        const SizedBox(height: 16),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(24),
                                          child: Stack(
                                            children: [
                                              Image.memory(
                                                _selectedImageBytes!,
                                                width: double.infinity,
                                                height: 240,
                                                fit: BoxFit.cover,
                                              ),
                                              const Positioned.fill(
                                                child: _PhotoGuideOverlay(),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _SectionCard(
                                  title: '신체 및 생활 정보',
                                  description: '각 항목은 모바일에서 바로 조절할 수 있도록 슬라이더 중심으로 구성했습니다.',
                                  child: Column(
                                    children: [
                                      LabeledSlider(
                                        label: '키',
                                        valueText: '${_height.round()} cm',
                                        value: _height,
                                        min: 140,
                                        max: 200,
                                        onChanged: (value) => setState(() => _height = value),
                                      ),
                                      LabeledSlider(
                                        label: '책상 높이',
                                        valueText: '${_deskHeight.round()} cm',
                                        value: _deskHeight,
                                        min: 55,
                                        max: 85,
                                        onChanged: (value) => setState(() => _deskHeight = value),
                                      ),
                                      LabeledSlider(
                                        label: '의자 높이',
                                        valueText: '${_chairHeight.round()} cm',
                                        value: _chairHeight,
                                        min: 35,
                                        max: 60,
                                        onChanged: (value) => setState(() => _chairHeight = value),
                                      ),
                                      LabeledSlider(
                                        label: '하루 스마트폰 사용시간',
                                        valueText: '${_phoneHours.toStringAsFixed(1)} 시간',
                                        value: _phoneHours,
                                        min: 0,
                                        max: 12,
                                        divisions: 24,
                                        onChanged: (value) => setState(() => _phoneHours = value),
                                      ),
                                      LabeledSlider(
                                        label: '하루 공부 시간',
                                        valueText: '${_studyHours.toStringAsFixed(1)} 시간',
                                        value: _studyHours,
                                        min: 0,
                                        max: 16,
                                        divisions: 32,
                                        onChanged: (value) => setState(() => _studyHours = value),
                                      ),
                                      LabeledSlider(
                                        label: '목 통증 정도',
                                        valueText: '${_painLevel.round()} 점',
                                        value: _painLevel,
                                        min: 0,
                                        max: 10,
                                        divisions: 10,
                                        onChanged: (value) => setState(() => _painLevel = value),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 20),
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton(
                                    onPressed: _isSubmitting ? null : _submit,
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 18),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(22),
                                      ),
                                    ),
                                    child: Text(
                                      _isSubmitting ? '분석 중...' : '자세 분석 시작',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Card(
                        color: const Color(0xFFFFFCF8),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: result == null
                              ? const _EmptyResultState()
                              : _ResultSection(
                                  result: result,
                                  imageBytes: _selectedImageBytes!,
                                  decodedImage: _decodedImage,
                                ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Card(
                        color: const Color(0xFFFFFCF8),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: _HistorySection(
                            inspectorNames: _savedInspectors,
                            selectedInspectorName: _selectedHistoryName,
                            entries: _historyEntries,
                            isLoading: _isHistoryLoading,
                            onInspectorChanged: _loadHistoryForName,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3E2616), Color(0xFF9C5421), Color(0xFFD68E52)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x331B120B),
            blurRadius: 36,
            offset: Offset(0, 20),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'POSTURE INSIGHT',
            style: theme.textTheme.labelLarge?.copyWith(
              color: const Color(0xFFFDE8D3),
              letterSpacing: 2.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '사진으로 거북목 자세를 분석합니다.',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '자세 사진과 생활 습관 정보를 함께 입력하면 CVA와 위험도를 추정하고, 개인 맞춤 피드백을 제공합니다.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: const Color(0xFFFFEADA),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0x22FFF3E7),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                const Icon(Icons.smartphone_outlined, color: Color(0xFFFFEADA)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '옆모습이 잘 보이게 촬영한 뒤 생활 습관 정보까지 함께 입력하면 분석 정확도가 높아집니다.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFFFF3EA),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.message, required this.tone});

  final String message;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final (background, foreground, icon) = switch (tone) {
      StatusTone.error => (
          const Color(0xFFFBE2DF),
          const Color(0xFFA13F31),
          Icons.error_outline,
        ),
      StatusTone.loading => (
          const Color(0xFFFFEFDB),
          const Color(0xFF9A611C),
          Icons.hourglass_top_rounded,
        ),
      StatusTone.done => (
          const Color(0xFFE2F2E4),
          const Color(0xFF2F6A39),
          Icons.check_circle_outline,
        ),
      StatusTone.idle => (
          Colors.white,
          const Color(0xFF6B5D51),
          Icons.info_outline,
        ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.description = '',
  });

  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F1E9),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF6B5D51)),
            ),
            const SizedBox(height: 18),
          ] else
            const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _CaptureGuideSheet extends StatelessWidget {
  const _CaptureGuideSheet();

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFFFFCF8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 5,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE6D6C5),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        '촬영 가이드',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '정확한 분석을 위해 아래 예시처럼 사람의 옆모습과 목-어깨 라인이 잘 보이게 촬영하세요.',
                        style: TextStyle(color: Color(0xFF6B5D51), height: 1.5),
                      ),
                      const SizedBox(height: 18),
                      Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.min(280, constraints.maxWidth),
                          ),
                          child: const AspectRatio(
                            aspectRatio: 3 / 4,
                            child: _GuidePreviewFrame(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const _GuideBullet(text: '어깨부터 귀까지 한 화면에 들어오게 세로로 촬영하세요.'),
                      const _GuideBullet(text: '정면이 아닌 완전한 옆모습에 가깝게 서 주세요.'),
                      const _GuideBullet(text: '얼굴과 어깨 윤곽이 보이도록 밝은 배경과 충분한 조명을 사용하세요.'),
                      const _GuideBullet(text: '머리카락이나 옷깃이 귀와 어깨를 가리지 않게 정리하세요.'),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          child: const Text('가이드 확인 후 촬영하기'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GuidePreviewFrame extends StatelessWidget {
  const _GuidePreviewFrame();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF4E4D2), Color(0xFFE8D2BE)],
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _PhotoGuideOverlay()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Text(
              '옆모습 정렬 예시',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: const Color(0xFF5F4737),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoGuideOverlay extends StatelessWidget {
  const _PhotoGuideOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0x990F0A07),
              Colors.transparent,
              const Color(0x660F0A07),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xCC2A211A),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    '귀와 어깨가 모두 보이게',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1.5,
                      color: const Color(0xCCFFE6CF),
                    ),
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFD7AA),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.only(right: 64),
                    color: const Color(0xCCFFE6CF),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xCC2A211A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    '몸이 기울지 않게 세우고, 측면으로 서서 촬영',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideBullet extends StatelessWidget {
  const _GuideBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 8, color: Color(0xFFBB5A1B)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFF5F5147), height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE4CC),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  valueText,
                  style: const TextStyle(
                    color: Color(0xFF8C4D1A),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _EmptyResultState extends StatelessWidget {
  const _EmptyResultState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F1E9),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Column(
        children: [
          Icon(Icons.insights_outlined, size: 42, color: Color(0xFF8C6B54)),
          SizedBox(height: 14),
          Text(
            '아직 분석 결과가 없습니다.',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),
          Text(
            '사진과 정보를 입력한 뒤 분석을 실행하면 CVA, 위험도, 맞춤 피드백이 여기 표시됩니다.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ResultSection extends StatelessWidget {
  const _ResultSection({
    required this.result,
    required this.imageBytes,
    required this.decodedImage,
  });

  final PostureAnalysisResult result;
  final Uint8List imageBytes;
  final ui.Image? decodedImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = [
      _MetricCard(label: 'CVA', value: '${result.cva.toStringAsFixed(1)}°'),
      _MetricCard(label: '위험도', value: result.risk.label, badgeColor: result.risk.color),
      _MetricCard(label: '좌표 신뢰도', value: '${(result.pointConfidence * 100).round()}%'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '분석 결과',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 16),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: cards.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisExtent: 112,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemBuilder: (context, index) => cards[index],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F1E9),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '자세 사진 기준점 시각화',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '업로드한 사진 위에 tragus와 어깨 또는 C7 기준점을 표시합니다.',
                style: theme.textTheme.bodyMedium?.copyWith(color: const Color(0xFF6B5D51)),
              ),
              const SizedBox(height: 14),
              if (decodedImage != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: AspectRatio(
                    aspectRatio: decodedImage!.width / decodedImage!.height,
                    child: CustomPaint(
                      painter: AnnotatedPhotoPainter(
                        image: decodedImage!,
                        tragus: result.tragus,
                        shoulder: result.shoulder,
                        cva: result.cva,
                      ),
                    ),
                  ),
                )
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.memory(imageBytes),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _InfoCard(
          title: '측정 근거',
          body: [
            result.measurementBasis,
            '계산식: 어깨 또는 C7 기준점과 귀의 tragus를 연결한 선과 수평선의 각도(CVA) = ${result.cva.toStringAsFixed(1)}°',
            '위험도 기준: 55도 이상 정상, 50도 이상 주의, 45도 이상 경도 거북목, 45도 미만 고위험.',
          ].join(' '),
        ),
        const SizedBox(height: 12),
        _InfoCard(
          title: '자세 분석',
          body: [result.postureSummary, ...result.postureObservations].join(' '),
        ),
        const SizedBox(height: 12),
        _InfoCard(
          title: '개인 맞춤 피드백',
          body: [result.personalizedFeedback, result.cautionNote].join(' '),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F1E9),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '추천 행동',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              for (final action in result.recommendedActions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Icon(Icons.circle, size: 10, color: Color(0xFFBB5A1B)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(action)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF4EA),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            '이 결과는 사진 기반 추정이며 의료 진단을 대체하지 않습니다. 통증이 심하거나 지속되면 전문의 평가가 필요합니다.',
            style: TextStyle(color: Color(0xFF7A5A44), height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.inspectorNames,
    required this.selectedInspectorName,
    required this.entries,
    required this.isLoading,
    required this.onInspectorChanged,
  });

  final List<String> inspectorNames;
  final String? selectedInspectorName;
  final List<AnalysisHistoryEntry> entries;
  final bool isLoading;
  final ValueChanged<String> onInspectorChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '개인별 검사 기록',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          '검사자 이름 기준으로 저장된 이력을 확인합니다.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF6B5D51),
          ),
        ),
        const SizedBox(height: 16),
        if (inspectorNames.isEmpty)
          const _HistoryEmptyState(
            message: '아직 저장된 검사 기록이 없습니다. 이름을 입력하고 분석을 실행하면 여기에 누적됩니다.',
          )
        else ...[
          DropdownButtonFormField<String>(
            initialValue: selectedInspectorName,
            decoration: const InputDecoration(
              labelText: '검사자 선택',
            ),
            items: inspectorNames
                .map(
                  (name) => DropdownMenuItem<String>(
                    value: name,
                    child: Text(name),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) {
                onInspectorChanged(value);
              }
            },
          ),
          const SizedBox(height: 16),
          if (isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: CircularProgressIndicator(),
              ),
            )
          else if (entries.isEmpty)
            const _HistoryEmptyState(
              message: '선택한 검사자의 저장 기록이 없습니다.',
            )
          else
            for (final entry in entries)
              _HistoryEntryCard(entry: entry),
        ],
      ],
    );
  }
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F1E9),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFF6B5D51), height: 1.5),
      ),
    );
  }
}

class _HistoryEntryCard extends StatelessWidget {
  const _HistoryEntryCard({required this.entry});

  final AnalysisHistoryEntry entry;

  Future<void> _showDetails(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _HistoryDetailDialog(entry: entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showDetails(context),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFFF8F1E9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.inspectorName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE4CC),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      entry.riskLabel,
                      style: const TextStyle(
                        color: Color(0xFF8C4D1A),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${formatHistoryDate(entry.analyzedAt)} · 모델 ${entry.model}',
                style: const TextStyle(color: Color(0xFF7A5A44)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _HistoryMetricChip(label: 'CVA', value: '${entry.cva.toStringAsFixed(1)}°'),
                  _HistoryMetricChip(label: '신뢰도', value: '${(entry.pointConfidence * 100).round()}%'),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                entry.postureSummary,
                style: const TextStyle(height: 1.5),
              ),
              if (entry.measurementBasis.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '측정 근거: ${entry.measurementBasis}',
                  style: const TextStyle(
                    color: Color(0xFF6B5D51),
                    height: 1.5,
                  ),
                ),
              ],
              if (entry.personalizedFeedback.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '피드백: ${entry.personalizedFeedback}',
                  style: const TextStyle(
                    color: Color(0xFF6B5D51),
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              const Row(
                children: [
                  Icon(Icons.visibility_outlined, size: 16, color: Color(0xFF8C6B54)),
                  SizedBox(width: 6),
                  Text(
                    '탭해서 당시 사진과 전체 결과 보기',
                    style: TextStyle(
                      color: Color(0xFF8C6B54),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryDetailDialog extends StatelessWidget {
  const _HistoryDetailDialog({required this.entry});

  final AnalysisHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final photoBytes = decodeHistoryImage(entry.photoBase64);
    final theme = Theme.of(context);
    final postureBody = [entry.postureSummary, ...entry.postureObservations]
        .where((text) => text.isNotEmpty)
        .join(' ');
    final feedbackBody = [entry.personalizedFeedback, entry.cautionNote]
        .where((text) => text.isNotEmpty)
        .join(' ');

    return Dialog(
      backgroundColor: const Color(0xFFFFFCF8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${entry.inspectorName} 검사 기록',
                        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  '${formatHistoryDate(entry.analyzedAt)} · 모델 ${entry.model}',
                  style: const TextStyle(color: Color(0xFF7A5A44)),
                ),
                const SizedBox(height: 16),
                if (photoBytes != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.memory(photoBytes),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F1E9),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Text(
                      '이 기록은 사진 저장 기능이 추가되기 전에 생성되어 당시 사진이 없습니다.',
                      style: TextStyle(color: Color(0xFF6B5D51), height: 1.5),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _HistoryMetricChip(label: 'CVA', value: '${entry.cva.toStringAsFixed(1)}°'),
                    _HistoryMetricChip(label: '위험도', value: entry.riskLabel),
                    _HistoryMetricChip(label: '신뢰도', value: '${(entry.pointConfidence * 100).round()}%'),
                  ],
                ),
                const SizedBox(height: 16),
                _InfoCard(title: '측정 근거', body: entry.measurementBasis),
                const SizedBox(height: 12),
                _InfoCard(title: '자세 분석', body: postureBody),
                const SizedBox(height: 12),
                _InfoCard(title: '개인 맞춤 피드백', body: feedbackBody),
                if (entry.recommendedActions.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F1E9),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '추천 행동',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 12),
                        for (final action in entry.recommendedActions)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Icon(Icons.circle, size: 10, color: Color(0xFFBB5A1B)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(child: Text(action)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryMetricChip extends StatelessWidget {
  const _HistoryMetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label $value',
        style: const TextStyle(
          color: Color(0xFF5F5147),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    this.badgeColor,
  });

  final String label;
  final String value;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final textWidget = badgeColor == null
        ? Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          )
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: badgeColor,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
            ),
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F1E9),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF7C6A5E),
              fontSize: 12,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w700,
            ),
          ),
          textWidget,
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F1E9),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(body, style: const TextStyle(height: 1.6)),
        ],
      ),
    );
  }
}

class AnnotatedPhotoPainter extends CustomPainter {
  AnnotatedPhotoPainter({
    required this.image,
    required this.tragus,
    required this.shoulder,
    required this.cva,
  });

  final ui.Image image;
  final AnalysisPoint tragus;
  final AnalysisPoint shoulder;
  final double cva;

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: image, fit: BoxFit.cover);

    final tragusPoint = Offset(tragus.x * size.width, tragus.y * size.height);
    final shoulderPoint = Offset(shoulder.x * size.width, shoulder.y * size.height);
    final strokeWidth = math.max(3.0, size.width / 120);
    final segmentPaint = Paint()
      ..color = const Color(0xFFC46F2A)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final baselinePaint = Paint()
      ..color = const Color(0xFF3A7D44)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    canvas.drawLine(shoulderPoint, tragusPoint, segmentPaint);
    canvas.drawLine(
      shoulderPoint,
      Offset(math.min(size.width - 16, shoulderPoint.dx + size.width * 0.2), shoulderPoint.dy),
      baselinePaint,
    );

    _drawPoint(canvas, size, tragusPoint, tragus.label, const Color(0xFFA93B2F));
    _drawPoint(canvas, size, shoulderPoint, shoulder.label, const Color(0xFF274690));

    final textPainter = TextPainter(
      text: TextSpan(
        text: 'CVA ${cva.toStringAsFixed(1)}°',
        style: TextStyle(
          color: const Color(0xFF2C241D),
          fontSize: math.max(16, size.width / 18),
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);
    textPainter.paint(canvas, const Offset(18, 18));
  }

  void _drawPoint(
    Canvas canvas,
    Size size,
    Offset point,
    String label,
    Color color,
  ) {
    final circlePaint = Paint()..color = color;
    canvas.drawCircle(point, math.max(6, size.width / 44), circlePaint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: const Color(0xFF2C241D),
          fontSize: math.max(12, size.width / 24),
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.6);

    textPainter.paint(
      canvas,
      Offset(point.dx + 12, math.max(10, point.dy - textPainter.height - 4)),
    );
  }

  @override
  bool shouldRepaint(covariant AnnotatedPhotoPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.tragus != tragus ||
        oldDelegate.shoulder != shoulder ||
        oldDelegate.cva != cva;
  }
}

Map<String, dynamic> buildRequestPayload({
  required String model,
  required UserProfile profile,
  required String mainPhotoUrl,
  String? refinementHint,
}) {
  final schema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'side_photo_assessment': {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'tragus_point': pointSchema(),
          'shoulder_or_c7_point': pointSchema(),
          'point_confidence': {'type': 'number'},
          'measurement_basis': {'type': 'string'},
          'posture_observations': {
            'type': 'array',
            'items': {'type': 'string'},
          },
        },
        'required': [
          'tragus_point',
          'shoulder_or_c7_point',
          'point_confidence',
          'measurement_basis',
          'posture_observations',
        ],
      },
      'posture_summary': {'type': 'string'},
      'personalized_feedback': {'type': 'string'},
      'recommended_actions': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'caution_note': {'type': 'string'},
    },
    'required': [
      'side_photo_assessment',
      'posture_summary',
      'personalized_feedback',
      'recommended_actions',
      'caution_note',
    ],
  };

  return {
    'model': model,
    'input': [
      {
        'role': 'system',
        'content': [
          {
            'type': 'input_text',
            'text': [
              '너는 한국어로 답하는 자세 분석 도우미다.',
              '반드시 side_photo_assessment 안에 업로드된 자세 사진 기준 tragus_point와 shoulder_or_c7_point를 정규화 좌표로 제공해라.',
              '정규화 좌표는 x, y를 0과 1 사이 숫자로 반환한다.',
              '측정 기준은 귀의 tragus와 C7 또는 어깨 기준점을 연결한 각도(CVA) 계산용이다.',
              'tragus_point는 보이는 귀의 외이도 입구 바로 앞 작은 연골 돌기 부근 중심, 즉 귀 중앙에 가장 가까운 점으로 잡아라.',
              'shoulder_or_c7_point는 보이는 쪽 어깨 끝(acromion) 중심 또는 C7 돌출부 중심 중 사진에서 더 확실한 인체 기준점의 중앙으로 잡아라.',
              '두 점 모두 반드시 사람의 윤곽선 또는 인체 내부 위에 있어야 하며, 배경, 머리카락 바깥, 옷 바깥, 빈 공간을 찍으면 안 된다.',
              '좌표를 내기 전에 내부적으로 두 점이 실제 인체 위에 있는지, tragus가 shoulder_or_c7_point보다 위쪽에 있는지 다시 확인하고 틀리면 수정해라.',
              '가능하면 사진에서 측면 정렬을 판단하고, 정면에 가까워 측정이 불확실하면 measurement_basis와 posture_observations에 그 한계를 분명히 적어라.',
              '기준점이 가려졌거나 흐리면 억지로 확정하지 말고 point_confidence를 낮춰라.',
              '의학적 진단처럼 단정하지 말고 사진 기반 추정이라고 명시한다.',
              '반드시 JSON 스키마를 지켜라. 설명 텍스트를 JSON 밖에 쓰지 마라.',
            ].join(' '),
          },
        ],
      },
      {
        'role': 'user',
        'content': [
          {
            'type': 'input_text',
            'text': [
              '다음 정보를 반영해서 자세를 분석해줘.',
              '키: ${profile.heightCm.round()}cm',
              '책상 높이: ${profile.deskHeightCm.round()}cm',
              '의자 높이: ${profile.chairHeightCm.round()}cm',
              '하루 스마트폰 사용시간: ${profile.smartphoneHoursPerDay.toStringAsFixed(1)}시간',
              '하루 공부 시간: ${profile.studyHoursPerDay.toStringAsFixed(1)}시간',
              '목 통증 정도: ${profile.neckPainLevel.round()}/10',
              '업로드된 사진 한 장에서 자세를 관찰하고 CVA 측정이 가능하면 tragus와 shoulder 또는 C7 기준점을 찾아 좌표를 반환해줘.',
              '귀 기준점은 귀 윤곽의 중앙이 아니라 tragus에 최대한 가깝게, 어깨 기준점은 어깨 외곽선이 아니라 어깨 중심 또는 C7 중심에 가깝게 잡아줘.',
              '기준점이 사람 밖에 있으면 안 되고, 사람이 프레임 한쪽에 치우쳐 있어도 전체 이미지 기준 정규화 좌표로 반환해줘.',
              '사진이 완전한 옆모습이 아니면 가장 합리적인 추정치를 주되, measurement_basis에 추정 한계를 적고, 메인 사진과 생활 정보를 종합해서 posture_summary와 personalized_feedback, recommended_actions를 작성해줘.',
              if (refinementHint != null && refinementHint.isNotEmpty) refinementHint,
            ].join('\n'),
          },
          {
            'type': 'input_image',
            'image_url': mainPhotoUrl,
            'detail': 'high',
          },
        ],
      },
    ],
    'text': {
      'format': {
        'type': 'json_schema',
        'name': 'posture_analysis',
        'schema': schema,
        'strict': true,
      },
    },
  };
}

Map<String, dynamic> pointSchema() {
  return {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'label': {'type': 'string'},
    },
    'required': ['x', 'y', 'label'],
  };
}

Future<Map<String, dynamic>> requestAnalysis({
  required String apiKey,
  required Map<String, dynamic> payload,
}) async {
  if (apiKey.isEmpty) {
    throw Exception('main.dart에 API 키를 하드코딩하거나 OpenAI API Key를 직접 입력하세요.');
  }

  final response = await http.post(
    Uri.parse('https://api.openai.com/v1/responses'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode(payload),
  );

  if (response.statusCode < 200 || response.statusCode >= 300) {
    final errorData = safeJsonMap(response.body);
    final message = errorData?['error']?['message'] as String?;
    throw Exception(message ?? 'API 호출 실패 (${response.statusCode})');
  }

  final responseData = jsonDecode(response.body) as Map<String, dynamic>;
  final rawText = extractOutputText(responseData);
  if (rawText == null || rawText.isEmpty) {
    throw Exception('API 응답에서 분석 결과를 읽지 못했습니다.');
  }

  try {
    return jsonDecode(rawText) as Map<String, dynamic>;
  } catch (_) {
    throw Exception('API가 예상한 JSON 형식으로 응답하지 않았습니다.');
  }
}

String? extractOutputText(Map<String, dynamic> responseData) {
  final direct = responseData['output_text'];
  if (direct is String && direct.isNotEmpty) {
    return direct;
  }

  final output = responseData['output'];
  if (output is! List) {
    return null;
  }

  for (final item in output) {
    if (item is! Map<String, dynamic>) {
      continue;
    }
    final content = item['content'];
    if (content is! List) {
      continue;
    }
    for (final contentItem in content) {
      if (contentItem is! Map<String, dynamic>) {
        continue;
      }
      if (contentItem['type'] == 'output_text' && contentItem['text'] is String) {
        return contentItem['text'] as String;
      }
    }
  }

  return null;
}

Map<String, dynamic>? safeJsonMap(String body) {
  try {
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

PostureAnalysisResult normalizeAnalysis(Map<String, dynamic> analysis) {
  final assessment = (analysis['side_photo_assessment'] as Map?)?.cast<String, dynamic>() ?? {};
  final tragus = clampPoint((assessment['tragus_point'] as Map?)?.cast<String, dynamic>() ?? {});
  final shoulder = clampPoint(
    (assessment['shoulder_or_c7_point'] as Map?)?.cast<String, dynamic>() ?? {},
  );
  final cva = calculateCva(tragus, shoulder);
  final risk = classifyRisk(cva);

  return PostureAnalysisResult(
    cva: cva,
    risk: risk,
    tragus: tragus,
    shoulder: shoulder,
    pointConfidence: (assessment['point_confidence'] as num?)?.toDouble() ?? 0,
    measurementBasis: analysisString(assessment['measurement_basis']),
    postureSummary: analysisString(analysis['posture_summary']),
    personalizedFeedback: analysisString(analysis['personalized_feedback']),
    recommendedActions: stringList(analysis['recommended_actions']),
    cautionNote: analysisString(analysis['caution_note']),
    postureObservations: stringList(assessment['posture_observations']),
  );
}

bool shouldRetryLandmarkDetection(PostureAnalysisResult result) {
  if (result.pointConfidence < 0.65) {
    return true;
  }

  return hasImplausibleLandmarkGeometry(result.tragus, result.shoulder);
}

bool isLandmarkDetectionBetter({
  required PostureAnalysisResult current,
  required PostureAnalysisResult candidate,
}) {
  final currentImplausible = hasImplausibleLandmarkGeometry(current.tragus, current.shoulder);
  final candidateImplausible = hasImplausibleLandmarkGeometry(candidate.tragus, candidate.shoulder);
  if (currentImplausible != candidateImplausible) {
    return !candidateImplausible;
  }

  return candidate.pointConfidence >= current.pointConfidence + 0.08;
}

bool hasImplausibleLandmarkGeometry(AnalysisPoint tragus, AnalysisPoint shoulder) {
  final deltaX = (tragus.x - shoulder.x).abs();
  final deltaY = shoulder.y - tragus.y;

  if (tragus.y >= shoulder.y) {
    return true;
  }

  if (deltaY < 0.05 || deltaY > 0.45) {
    return true;
  }

  if (deltaX > 0.35) {
    return true;
  }

  if (_isNearImageEdge(tragus) || _isNearImageEdge(shoulder)) {
    return true;
  }

  return false;
}

bool _isNearImageEdge(AnalysisPoint point) {
  const edgeMargin = 0.02;
  return point.x <= edgeMargin ||
      point.x >= 1 - edgeMargin ||
      point.y <= edgeMargin ||
      point.y >= 1 - edgeMargin;
}

String buildLandmarkRefinementHint(PostureAnalysisResult result) {
  return [
    '이전 기준점 후보를 다시 검토해서 더 정확한 귀 중심과 어깨 중심을 찾아줘.',
    '이전 tragus 후보: x=${result.tragus.x.toStringAsFixed(3)}, y=${result.tragus.y.toStringAsFixed(3)}.',
    '이전 shoulder/C7 후보: x=${result.shoulder.x.toStringAsFixed(3)}, y=${result.shoulder.y.toStringAsFixed(3)}.',
    '이전 좌표는 사람 밖이거나 기준점 중심에서 벗어났을 가능성이 있으니, 반드시 사람 내부의 해부학적 중심점으로 다시 잡아줘.',
    '재검토 후에도 확실하지 않으면 point_confidence를 낮추고 measurement_basis에 불확실성을 적어줘.',
  ].join(' ');
}

AnalysisPoint clampPoint(Map<String, dynamic> point) {
  return AnalysisPoint(
    x: clamp((point['x'] as num?)?.toDouble() ?? 0, 0, 1),
    y: clamp((point['y'] as num?)?.toDouble() ?? 0, 0, 1),
    label: analysisString(point['label']).isEmpty ? '기준점' : analysisString(point['label']),
  );
}

double clamp(double value, double min, double max) {
  if (!value.isFinite) {
    return min;
  }

  return math.min(math.max(value, min), max);
}

double calculateCva(AnalysisPoint tragus, AnalysisPoint shoulder) {
  final deltaX = (tragus.x - shoulder.x).abs();
  final deltaY = (tragus.y - shoulder.y).abs();
  if (deltaX == 0 && deltaY == 0) {
    return 0;
  }

  final radians = math.atan2(deltaY, deltaX == 0 ? 0.0001 : deltaX);
  return double.parse((radians * (180 / math.pi)).toStringAsFixed(1));
}

RiskLevel classifyRisk(double cva) {
  if (cva >= 55) {
    return const RiskLevel(label: '정상', color: Color(0xFF3A7D44));
  }

  if (cva >= 50) {
    return const RiskLevel(label: '주의', color: Color(0xFFCC8B1D));
  }

  if (cva >= 45) {
    return const RiskLevel(label: '경도 거북목', color: Color(0xFFC9671E));
  }

  return const RiskLevel(label: '고위험', color: Color(0xFFA93B2F));
}

String analysisString(Object? value) => value is String ? value : '';

List<String> stringList(Object? value) {
  if (value is! List) {
    return const [];
  }

  return value.whereType<String>().toList(growable: false);
}

String imageBytesToDataUrl(Uint8List bytes) {
  final encoded = base64Encode(bytes);
  return 'data:image/jpeg;base64,$encoded';
}

Future<ui.Image> decodeUiImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

class UserProfile {
  const UserProfile({
    required this.heightCm,
    required this.deskHeightCm,
    required this.chairHeightCm,
    required this.smartphoneHoursPerDay,
    required this.studyHoursPerDay,
    required this.neckPainLevel,
  });

  final double heightCm;
  final double deskHeightCm;
  final double chairHeightCm;
  final double smartphoneHoursPerDay;
  final double studyHoursPerDay;
  final double neckPainLevel;
}

class PostureAnalysisResult {
  const PostureAnalysisResult({
    required this.cva,
    required this.risk,
    required this.tragus,
    required this.shoulder,
    required this.pointConfidence,
    required this.measurementBasis,
    required this.postureSummary,
    required this.personalizedFeedback,
    required this.recommendedActions,
    required this.cautionNote,
    required this.postureObservations,
  });

  final double cva;
  final RiskLevel risk;
  final AnalysisPoint tragus;
  final AnalysisPoint shoulder;
  final double pointConfidence;
  final String measurementBasis;
  final String postureSummary;
  final String personalizedFeedback;
  final List<String> recommendedActions;
  final String cautionNote;
  final List<String> postureObservations;
}

class AnalysisHistoryEntry {
  const AnalysisHistoryEntry({
    required this.id,
    required this.inspectorName,
    required this.analyzedAt,
    required this.model,
    required this.cva,
    required this.riskLabel,
    required this.pointConfidence,
    required this.postureSummary,
    required this.personalizedFeedback,
    required this.measurementBasis,
    required this.cautionNote,
    required this.postureObservations,
    required this.recommendedActions,
    required this.photoBase64,
  });

  factory AnalysisHistoryEntry.create({
    required String inspectorName,
    required DateTime analyzedAt,
    required String model,
    required double cva,
    required String riskLabel,
    required double pointConfidence,
    required String postureSummary,
    required String personalizedFeedback,
    required String measurementBasis,
    required String cautionNote,
    required List<String> postureObservations,
    required List<String> recommendedActions,
    required String photoBase64,
  }) {
    return AnalysisHistoryEntry(
      id: null,
      inspectorName: inspectorName,
      analyzedAt: analyzedAt,
      model: model,
      cva: cva,
      riskLabel: riskLabel,
      pointConfidence: pointConfidence,
      postureSummary: postureSummary,
      personalizedFeedback: personalizedFeedback,
      measurementBasis: measurementBasis,
      cautionNote: cautionNote,
      postureObservations: postureObservations,
      recommendedActions: recommendedActions,
      photoBase64: photoBase64,
    );
  }

  factory AnalysisHistoryEntry.fromMap(Map<String, Object?> map) {
    return AnalysisHistoryEntry(
      id: map['id'] as int?,
      inspectorName: map['inspector_name'] as String? ?? '',
      analyzedAt: DateTime.tryParse(map['analyzed_at'] as String? ?? '') ?? DateTime.now(),
      model: map['model'] as String? ?? '',
      cva: (map['cva'] as num?)?.toDouble() ?? 0,
      riskLabel: map['risk_label'] as String? ?? '',
      pointConfidence: (map['point_confidence'] as num?)?.toDouble() ?? 0,
      postureSummary: map['posture_summary'] as String? ?? '',
      personalizedFeedback: map['personalized_feedback'] as String? ?? '',
      measurementBasis: map['measurement_basis'] as String? ?? '',
      cautionNote: map['caution_note'] as String? ?? '',
      postureObservations: decodeStringList(map['posture_observations_json'] as String?),
      recommendedActions: decodeStringList(map['recommended_actions_json'] as String?),
      photoBase64: map['photo_base64'] as String? ?? '',
    );
  }

  final int? id;
  final String inspectorName;
  final DateTime analyzedAt;
  final String model;
  final double cva;
  final String riskLabel;
  final double pointConfidence;
  final String postureSummary;
  final String personalizedFeedback;
  final String measurementBasis;
  final String cautionNote;
  final List<String> postureObservations;
  final List<String> recommendedActions;
  final String photoBase64;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'inspector_name': inspectorName,
      'analyzed_at': analyzedAt.toIso8601String(),
      'model': model,
      'cva': cva,
      'risk_label': riskLabel,
      'point_confidence': pointConfidence,
      'posture_summary': postureSummary,
      'personalized_feedback': personalizedFeedback,
      'measurement_basis': measurementBasis,
      'caution_note': cautionNote,
      'posture_observations_json': jsonEncode(postureObservations),
      'recommended_actions_json': jsonEncode(recommendedActions),
      'photo_base64': photoBase64,
    };
  }
}

class AnalysisHistoryDatabase {
  AnalysisHistoryDatabase._();

  static final AnalysisHistoryDatabase instance = AnalysisHistoryDatabase._();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    final databasePath = await getDatabasesPath();
    _database = await openDatabase(
      p.join(databasePath, 'analysis_history.db'),
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE analysis_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            inspector_name TEXT NOT NULL,
            analyzed_at TEXT NOT NULL,
            model TEXT NOT NULL,
            cva REAL NOT NULL,
            risk_label TEXT NOT NULL,
            point_confidence REAL NOT NULL,
            posture_summary TEXT NOT NULL,
            personalized_feedback TEXT NOT NULL,
            measurement_basis TEXT NOT NULL,
            caution_note TEXT NOT NULL,
            posture_observations_json TEXT NOT NULL,
            recommended_actions_json TEXT NOT NULL,
            photo_base64 TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute("ALTER TABLE analysis_history ADD COLUMN caution_note TEXT NOT NULL DEFAULT ''");
          await db.execute("ALTER TABLE analysis_history ADD COLUMN posture_observations_json TEXT NOT NULL DEFAULT '[]'");
          await db.execute("ALTER TABLE analysis_history ADD COLUMN recommended_actions_json TEXT NOT NULL DEFAULT '[]'");
          await db.execute("ALTER TABLE analysis_history ADD COLUMN photo_base64 TEXT NOT NULL DEFAULT ''");
        }
      },
    );

    return _database!;
  }

  Future<void> insertEntry(AnalysisHistoryEntry entry) async {
    final db = await database;
    await db.insert('analysis_history', entry.toMap()..remove('id'));
  }

  Future<List<String>> fetchInspectorNames() async {
    final db = await database;
    final rows = await db.query(
      'analysis_history',
      columns: ['inspector_name'],
      distinct: true,
      orderBy: 'inspector_name COLLATE NOCASE ASC',
    );

    return rows
        .map((row) => row['inspector_name'] as String? ?? '')
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<AnalysisHistoryEntry>> fetchEntriesForInspector(String inspectorName) async {
    final db = await database;
    final rows = await db.query(
      'analysis_history',
      where: 'inspector_name = ?',
      whereArgs: [inspectorName],
      orderBy: 'analyzed_at DESC',
    );

    return rows.map(AnalysisHistoryEntry.fromMap).toList(growable: false);
  }
}

class AnalysisPoint {
  const AnalysisPoint({required this.x, required this.y, required this.label});

  final double x;
  final double y;
  final String label;
}

class RiskLevel {
  const RiskLevel({required this.label, required this.color});

  final String label;
  final Color color;
}

enum StatusTone { idle, loading, done, error }

String formatHistoryDate(DateTime dateTime) {
  final month = dateTime.month.toString().padLeft(2, '0');
  final day = dateTime.day.toString().padLeft(2, '0');
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  return '${dateTime.year}.$month.$day $hour:$minute';
}

List<String> decodeStringList(String? value) {
  if (value == null || value.isEmpty) {
    return const [];
  }

  try {
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      return const [];
    }
    return decoded.whereType<String>().toList(growable: false);
  } catch (_) {
    return const [];
  }
}

Uint8List? decodeHistoryImage(String? photoBase64) {
  if (photoBase64 == null || photoBase64.isEmpty) {
    return null;
  }

  try {
    return base64Decode(photoBase64);
  } catch (_) {
    return null;
  }
}
