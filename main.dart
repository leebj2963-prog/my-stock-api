import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '나만의 매수 전략 (Plan Stock)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  List<ChartData> _chartData = [];
  bool _isLoading = true;

  final TextEditingController _searchController = TextEditingController(
    text: '삼성전자 (005930)',
  );
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _stopLossController = TextEditingController();
  final TextEditingController _hlineController = TextEditingController();

  final FocusNode _searchFocusNode = FocusNode();

  List<Map<String, dynamic>> _currentPlans = [];
  List<Map<String, dynamic>> _hLines = [];
  int? _stopLossPrice;
  double? _previewPrice;

  DateTime _selectedDate = DateTime.now();
  int _selectedPlanIndex = -1;

  double _avgPrice = 0.0;
  int _totalAmount = 0;
  int _totalQty = 0;

  List<Map<String, String>> _stockList = [];
  final NumberFormat f = NumberFormat('#,###');

  final List<Color> _hlineColors = const [
    Color(0xFFE67E00),
    Color(0xFF9B59B6),
    Color(0xFF27AE60),
    Color(0xFFE74C3C),
    Color(0xFF1ABC9C),
    Color(0xFFF39C12),
    Color(0xFF2980B9),
    Color(0xFF8E44AD),
    Color(0xFFD35400),
    Color(0xFF16A085),
  ];
  int _colorIndex = 0;

  double _chartHeightFactor = 0.55;

  late ZoomPanBehavior _zoomPanBehavior;
  late ZoomPanBehavior _volumeZoomBehavior;
  late TrackballBehavior _trackballBehavior;
  final ValueNotifier<List<double>> _zoomNotifier = ValueNotifier([1.0, 0.0]);

  ChartAxisController? _priceAxisController;
  ChartAxisController? _volAxisController;
  bool _isSyncing = false;

  // 🌟 [수정] 실수로 누락되었던 Y축 범위 저장 변수들을 다시 추가했습니다!
  double? _yAxisMin;
  double? _yAxisMax;
  double? _volAxisMax;

  ChartSeriesController? _seriesController;
  int? _draggedHLineIndex;
  bool _isDraggingStopLoss = false;
  bool _isPanningEnabled = true;

  @override
  void initState() {
    super.initState();

    _zoomPanBehavior = ZoomPanBehavior(
      enablePinching: true,
      enablePanning: true,
      enableMouseWheelZooming: true,
      zoomMode: ZoomMode.x,
    );
    _volumeZoomBehavior = ZoomPanBehavior(
      enablePanning: true,
      zoomMode: ZoomMode.x,
    );

    _trackballBehavior = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.longPress,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.nearestPoint,
      tooltipSettings: const InteractiveTooltip(
        enable: true,
        format:
            'point.x\n시가: point.open\n고가: point.high\n저가: point.low\n종가: point.close',
      ),
    );

    _priceController.addListener(_updatePreviewLine);

    fetchStockList();
    fetchStockData('005930');
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _zoomNotifier.dispose();
    _priceController.removeListener(_updatePreviewLine);
    _searchController.dispose();
    _priceController.dispose();
    _qtyController.dispose();
    _stopLossController.dispose();
    _hlineController.dispose();
    super.dispose();
  }

  void _setDragState(bool dragging, {int? hLineIdx, bool stopLoss = false}) {
    setState(() {
      _isPanningEnabled = !dragging;
      _zoomPanBehavior = ZoomPanBehavior(
        enablePinching: _isPanningEnabled,
        enablePanning: _isPanningEnabled,
        enableMouseWheelZooming: true,
        zoomMode: ZoomMode.x,
      );
      _volumeZoomBehavior = ZoomPanBehavior(
        enablePanning: _isPanningEnabled,
        zoomMode: ZoomMode.x,
      );
      _draggedHLineIndex = hLineIdx;
      _isDraggingStopLoss = stopLoss;
    });
  }

  Future<void> _savePlansSilently() async {
    String code = _getCurrentCode();
    if (code.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> dataToSave = {
      'plans': _currentPlans,
      'hLines': _hLines,
      'stopLoss': _stopLossPrice,
    };
    await prefs.setString('plan_$code', jsonEncode(dataToSave));
  }

  void _handleZoom(bool isZoomIn) {
    if (_chartData.isEmpty) return;
    final total = _chartData.length.toDouble();
    final cur = _zoomNotifier.value;
    final curCandles = (cur[0] * total).round();

    final int targetCandles = isZoomIn ? (curCandles - 10) : (curCandles + 10);
    final newCandles = targetCandles.clamp(10, total.toInt());
    final newFactor = newCandles / total;

    final double newPos = isZoomIn
        ? (cur[1] + (cur[0] - newFactor)).clamp(
            0.0,
            (1.0 - newFactor).clamp(0.0, 1.0),
          )
        : (cur[1] - (newFactor - cur[0])).clamp(
            0.0,
            (1.0 - newFactor).clamp(0.0, 1.0),
          );

    _zoomNotifier.value = [newFactor, newPos];
    _priceAxisController?.zoomFactor = newFactor;
    _priceAxisController?.zoomPosition = newPos;
    _volAxisController?.zoomFactor = newFactor;
    _volAxisController?.zoomPosition = newPos;
    _recalcYAxis(newFactor, newPos);
  }

  void _recalcYAxis(double zoomFactor, double zoomPosition) {
    if (_chartData.isEmpty) return;
    final int total = _chartData.length;

    final int startIdx = ((zoomPosition * total).floor() - 1).clamp(
      0,
      total > 0 ? total - 1 : 0,
    );
    final int count = (zoomFactor * total).ceil() + 2;
    final int endIdx = (startIdx + count).clamp(1, total);

    double maxVal = -double.infinity;
    double minVal = double.infinity;
    double maxVol = 0;

    for (int i = startIdx; i < endIdx; i++) {
      final d = _chartData[i];
      if (d.isSuspended) continue;
      if (d.high > maxVal) maxVal = d.high;
      if (d.low < minVal) minVal = d.low;
      for (final ma in [d.ma5, d.ma20, d.ma60, d.ma120, d.ma240]) {
        if (ma != null && ma > 0) {
          if (ma > maxVal) maxVal = ma;
          if (ma < minVal) minVal = ma;
        }
      }
      if (d.volume > maxVol) maxVol = d.volume.toDouble();
    }

    double? newPriceMin;
    double? newPriceMax;
    if (maxVal != -double.infinity && minVal != double.infinity) {
      final double lastClose = _chartData.last.close;
      final double devUp = maxVal - lastClose;
      final double devDown = lastClose - minVal;
      final double halfRange = max(devUp, devDown);
      if (halfRange > 0) {
        final double padding = halfRange * 0.10;
        newPriceMin = lastClose - halfRange - padding;
        newPriceMax = lastClose + halfRange + padding;
      }
    }

    final double? newVolMax = maxVol > 0 ? maxVol * (1 / 0.85) : null;

    if (newPriceMin != _yAxisMin ||
        newPriceMax != _yAxisMax ||
        newVolMax != _volAxisMax) {
      setState(() {
        if (newPriceMin != null) _yAxisMin = newPriceMin;
        if (newPriceMax != null) _yAxisMax = newPriceMax;
        if (newVolMax != null) _volAxisMax = newVolMax;
      });
    }
  }

  void _updatePreviewLine() {
    int? p = int.tryParse(_priceController.text.replaceAll(',', ''));
    setState(() {
      _previewPrice = (p != null && p > 0) ? p.toDouble() : null;
    });
  }

  Future<void> fetchStockList() async {
    final url = Uri.parse('https://my-stock-api-bjjv.onrender.com/stocks/krx');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> decodedData = json.decode(
            utf8.decode(response.bodyBytes),
          );
          final List<dynamic> jsonData = decodedData['data'];

          setState(() {
            _stockList = jsonData
                .map<Map<String, String>>(
                  (item) => {
                    'Code': item['Code'].toString(),
                    'Name': item['Name'].toString(),
                    'Qwerty': _getQwerty(item['Name'].toString()),
                  },
                )
                .toList();
          });
        } catch (e) {
          debugPrint('종목 리스트 JSON 파싱 에러: $e');
        }
      }
    } catch (e) {
      debugPrint('종목 리스트 API 네트워크 호출 실패: $e');
    }
  }

  void _searchStock({bool fromLoad = false}) {
    String input = _searchController.text.trim();
    if (input.isEmpty) return;

    String targetCode = input;
    if (input.contains('(') && input.contains(')')) {
      targetCode = input.split('(').last.replaceAll(')', '').trim();
    }

    if (int.tryParse(targetCode) == null) {
      if (_stockList.isEmpty) return;

      final String lowerTarget = targetCode.toLowerCase();
      final String qwertyTarget = _getQwerty(targetCode).toLowerCase();

      var found = _stockList
          .where((s) => s['Name']!.toLowerCase() == lowerTarget)
          .toList();

      if (found.isEmpty) {
        found = _stockList
            .where((s) => s['Name']!.toLowerCase().contains(lowerTarget))
            .toList();
      }

      if (found.isEmpty) {
        found = _stockList
            .where(
              (s) =>
                  s['Name']!.toLowerCase().contains(qwertyTarget) ||
                  (s['Qwerty'] ?? '').contains(qwertyTarget),
            )
            .toList();
      }

      if (found.isNotEmpty) {
        targetCode = found.first['Code']!;
        _searchController.text = '${found.first['Name']} ($targetCode)';
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('해당 종목을 찾을 수 없습니다.')));
        return;
      }
    } else {
      if (_stockList.isNotEmpty) {
        var found = _stockList.where((s) => s['Code'] == targetCode).toList();
        if (found.isNotEmpty) {
          _searchController.text = '${found.first['Name']} ($targetCode)';
        }
      }
    }

    setState(() {
      _isLoading = true;
      if (!fromLoad) {
        _currentPlans.clear();
        _hLines.clear();
        _stopLossPrice = null;
        _avgPrice = 0.0;
        _totalAmount = 0;
        _totalQty = 0;
      }
      _previewPrice = null;
      _selectedPlanIndex = -1;
      _priceController.clear();
      _qtyController.clear();
      _zoomNotifier.value = [1.0, 0.0];
      _yAxisMin = null;
      _yAxisMax = null;
      _volAxisMax = null;
    });
    FocusScope.of(context).unfocus();
    fetchStockData(targetCode);
  }

  Future<void> fetchStockData(String code) async {
    final url = Uri.parse(
      'https://my-stock-api-bjjv.onrender.com/stock/$code?days=300',
    );

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        try {
          final Map<String, dynamic> decodedData = json.decode(
            utf8.decode(response.bodyBytes),
          );
          final List<dynamic> jsonData = decodedData['data'];

          List<ChartData> loadedData = [];

          for (var item in jsonData) {
            loadedData.add(
              ChartData(
                item['Date'].toString().split(' ')[0],
                double.tryParse(item['Open'].toString()) ?? 0.0,
                double.tryParse(item['High'].toString()) ?? 0.0,
                double.tryParse(item['Low'].toString()) ?? 0.0,
                double.tryParse(item['Close'].toString()) ?? 0.0,
                int.tryParse(item['Volume'].toString()) ?? 0,
                _parseDoubleSafe(item['MA5']),
                _parseDoubleSafe(item['MA20']),
                _parseDoubleSafe(item['MA60']),
                _parseDoubleSafe(item['MA120']),
                _parseDoubleSafe(item['MA240']),
              ),
            );
          }

          for (int i = 0; i < loadedData.length; i++) {
            bool isSuspended = loadedData[i].volume == 0;
            bool prevSuspended = i > 0 && loadedData[i - 1].volume == 0;
            bool nextSuspended =
                i < loadedData.length - 1 && loadedData[i + 1].volume == 0;

            if (isSuspended) {
              loadedData[i].isSuspended = true;
              loadedData[i].suspendClose = loadedData[i].close;
            } else if (prevSuspended || nextSuspended) {
              loadedData[i].suspendClose = loadedData[i].close;
            }
          }

          const int defaultVisibleDays = 60;
          final int total = loadedData.length;
          final double zoomFactor = total > defaultVisibleDays
              ? defaultVisibleDays / total
              : 1.0;
          final double zoomPosition = total > defaultVisibleDays
              ? 1.0 - zoomFactor
              : 0.0;

          setState(() {
            _chartData = loadedData;
            _isLoading = false;
            _zoomNotifier.value = [zoomFactor, zoomPosition];

            if (loadedData.isNotEmpty) {
              final double lastClose = loadedData.last.close;
              if (lastClose > 0) {
                final int startIdx = (loadedData.length - defaultVisibleDays)
                    .clamp(0, loadedData.length);
                final visibleData = loadedData.sublist(startIdx);

                double maxVal = lastClose;
                double minVal = lastClose;
                for (final d in visibleData) {
                  if (d.isSuspended) continue;
                  if (d.high > maxVal) maxVal = d.high;
                  if (d.low < minVal) minVal = d.low;
                  for (final ma in [d.ma5, d.ma20, d.ma60, d.ma120, d.ma240]) {
                    if (ma != null && ma > 0) {
                      if (ma > maxVal) maxVal = ma;
                      if (ma < minVal) minVal = ma;
                    }
                  }
                }

                final double devUp = maxVal - lastClose;
                final double devDown = lastClose - minVal;
                final double halfRange = max(devUp, devDown);
                if (halfRange > 0) {
                  final double padding = halfRange * 0.10;
                  _yAxisMin = lastClose - halfRange - padding;
                  _yAxisMax = lastClose + halfRange + padding;
                }

                double maxVol = 0;
                for (final d in visibleData) {
                  if (!d.isSuspended && d.volume > maxVol) {
                    maxVol = d.volume.toDouble();
                  }
                }
                if (maxVol > 0) _volAxisMax = maxVol * (1 / 0.85);
              }
            }
          });

          Future.delayed(Duration.zero, () {
            _priceAxisController?.zoomFactor = zoomFactor;
            _priceAxisController?.zoomPosition = zoomPosition;
            _volAxisController?.zoomFactor = zoomFactor;
            _volAxisController?.zoomPosition = zoomPosition;
          });
        } catch (e) {
          setState(() {
            _isLoading = false;
          });
          debugPrint('🚨 데이터 파싱 에러: $e');
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('서버 응답 형식이 올바르지 않습니다.')));
        }
      } else {
        setState(() {
          _isLoading = false;
        });
        debugPrint('🚨 서버 에러 상태 코드: ${response.statusCode}');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('데이터를 불러오지 못했습니다. (서버 에러: ${response.statusCode})'),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      debugPrint('🚨 네트워크 에러: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('서버와 연결할 수 없습니다. 인터넷 상태를 확인해주세요.')),
      );
    }
  }

  double? _parseDoubleSafe(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return null;
    return double.tryParse(value.toString());
  }

  void _addPlan() {
    final int price =
        int.tryParse(_priceController.text.replaceAll(',', '')) ?? 0;
    final int qty = int.tryParse(_qtyController.text.replaceAll(',', '')) ?? 0;
    if (price <= 0 || qty <= 0) return;

    setState(() {
      _currentPlans.add({
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        'price': price,
        'qty': qty,
        'total': price * qty,
      });
      _currentPlans.sort(
        (a, b) => a['date'].toString().compareTo(b['date'].toString()),
      );
      _calculateSummary();
      _clearInputs();
    });
    FocusScope.of(context).unfocus();
  }

  void _modifyPlan() {
    if (_selectedPlanIndex < 0 || _selectedPlanIndex >= _currentPlans.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('수정할 항목을 목록에서 먼저 선택하세요.')));
      return;
    }
    final int price =
        int.tryParse(_priceController.text.replaceAll(',', '')) ?? 0;
    final int qty = int.tryParse(_qtyController.text.replaceAll(',', '')) ?? 0;
    if (price <= 0 || qty <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('매수가와 수량을 올바르게 입력하세요.')));
      return;
    }

    setState(() {
      _currentPlans[_selectedPlanIndex] = {
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        'price': price,
        'qty': qty,
        'total': price * qty,
      };
      _currentPlans.sort(
        (a, b) => a['date'].toString().compareTo(b['date'].toString()),
      );
      _calculateSummary();
      _clearInputs();
    });
    FocusScope.of(context).unfocus();
  }

  void _deletePlan(int index) {
    setState(() {
      _currentPlans.removeAt(index);
      _calculateSummary();
    });
  }

  void _calculateSummary() {
    _totalAmount = 0;
    _totalQty = 0;
    for (var plan in _currentPlans) {
      _totalAmount += (plan['total'] as num).toInt();
      _totalQty += (plan['qty'] as num).toInt();
    }
    _avgPrice = _totalQty > 0 ? _totalAmount / _totalQty : 0.0;
  }

  void _clearInputs() {
    _priceController.clear();
    _qtyController.clear();
    _selectedPlanIndex = -1;
  }

  void _resetAllData() {
    setState(() {
      _currentPlans.clear();
      _hLines.clear();
      _stopLossPrice = null;
      _calculateSummary();
      _clearInputs();
    });
    FocusScope.of(context).unfocus();
  }

  Future<void> _pickDate() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  void _setStopLoss() {
    final int price =
        int.tryParse(_stopLossController.text.replaceAll(',', '')) ?? 0;
    if (price <= 0) return;
    setState(() {
      _stopLossPrice = price;
      _stopLossController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  void _clearStopLoss() {
    setState(() {
      _stopLossPrice = null;
      _stopLossController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  void _addHLine() {
    final int price =
        int.tryParse(_hlineController.text.replaceAll(',', '')) ?? 0;
    if (price <= 0) return;
    setState(() {
      _hLines.add({
        'price': price,
        'color': _hlineColors[_colorIndex % _hlineColors.length].toARGB32(),
      });
      _colorIndex++;
      _hlineController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  void _deleteHLine(int index) {
    setState(() {
      _hLines.removeAt(index);
    });
  }

  void _editHLinePrice(int index) {
    TextEditingController editCtrl = TextEditingController(
      text: _hLines[index]['price'].toString(),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('수평선 가격 수정'),
        content: TextField(
          controller: editCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _hLines[index]['price'] =
                    int.tryParse(editCtrl.text) ?? _hLines[index]['price'];
              });
              Navigator.pop(ctx);
            },
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  String _getCurrentCode() {
    String input = _searchController.text.trim();
    if (input.contains('(') && input.contains(')')) {
      return input.split('(').last.replaceAll(')', '').trim();
    }
    return input;
  }

  Future<void> _savePlans() async {
    String code = _getCurrentCode();
    if (code.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> dataToSave = {
      'plans': _currentPlans,
      'hLines': _hLines,
      'stopLoss': _stopLossPrice,
    };
    await prefs.setString('plan_$code', jsonEncode(dataToSave));

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('[$code] 매수 계획 및 설정이 저장되었습니다!')));
  }

  Future<void> _showLoadDialog() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> keys =
        prefs.getKeys().where((k) => k.startsWith('plan_')).toList()..sort();

    if (keys.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('저장된 매수 계획이 없습니다.')));
      return;
    }

    if (!mounted) return;

    final Set<String> selected = {};

    await showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (stateCtx, setDialogState) {
          final bool allSelected =
              keys.isNotEmpty && keys.every((k) => selected.contains(k));

          return AlertDialog(
            title: const Text('📂 저장된 계획 불러오기'),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child: Column(
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: allSelected,
                        tristate: false,
                        onChanged: (val) {
                          setDialogState(() {
                            if (allSelected) {
                              selected.clear();
                            } else {
                              selected.addAll(keys);
                            }
                          });
                        },
                      ),
                      const Text(
                        '전체 선택',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      if (selected.isNotEmpty)
                        Text(
                          '${selected.length}개 선택됨',
                          style: const TextStyle(
                            color: Colors.blue,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: keys.length,
                      itemBuilder: (context, index) {
                        final key = keys[index];
                        final code = key.replaceAll('plan_', '');
                        final name =
                            _stockList.firstWhere(
                              (s) => s['Code'] == code,
                              orElse: () => <String, String>{
                                'Name': '알수없음',
                                'Code': code,
                              },
                            )['Name'] ??
                            '알수없음';
                        final isChecked = selected.contains(key);
                        return ListTile(
                          dense: true,
                          leading: Checkbox(
                            value: isChecked,
                            onChanged: (val) {
                              setDialogState(() {
                                if (val == true) {
                                  selected.add(key);
                                } else {
                                  selected.remove(key);
                                }
                              });
                            },
                          ),
                          title: Text(
                            '$name ($code)',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onTap: () {
                            final jsonStr = prefs.getString(key);
                            if (jsonStr != null) {
                              _loadData(code, jsonStr);
                            }
                            if (stateCtx.mounted) Navigator.pop(stateCtx);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton.icon(
                onPressed: selected.isEmpty
                    ? null
                    : () async {
                        final confirm = await showDialog<bool>(
                          context: stateCtx,
                          builder: (c) => AlertDialog(
                            title: const Text('선택 삭제'),
                            content: Text('선택한 ${selected.length}개 항목을 삭제할까요?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('취소'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text(
                                  '삭제',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          for (final k in selected) {
                            await prefs.remove(k);
                          }
                          if (!stateCtx.mounted) return;
                          Navigator.pop(stateCtx);
                          if (mounted) {
                            _showLoadDialog();
                          }
                        }
                      },
                icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                label: const Text('선택 삭제', style: TextStyle(color: Colors.red)),
              ),
              TextButton.icon(
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: stateCtx,
                    builder: (c) => AlertDialog(
                      title: const Text('전체 삭제'),
                      content: const Text('저장된 계획을 모두 삭제할까요?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('취소'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text(
                            '삭제',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    for (final k in keys) {
                      await prefs.remove(k);
                    }
                    if (!stateCtx.mounted) return;
                    Navigator.pop(stateCtx);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('전체 삭제되었습니다.')),
                      );
                    }
                  }
                },
                icon: const Icon(
                  Icons.delete_forever,
                  size: 18,
                  color: Colors.orange,
                ),
                label: const Text(
                  '전체 삭제',
                  style: TextStyle(color: Colors.orange),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(stateCtx),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _loadData(String code, String jsonStr) {
    Map<String, dynamic> data = jsonDecode(jsonStr);
    final stockItem = _stockList.firstWhere(
      (s) => s['Code'] == code,
      orElse: () => <String, String>{'Name': code, 'Code': code},
    );

    List<Map<String, dynamic>> plans =
        List<Map<String, dynamic>>.from(
          data['plans'] ?? [],
        ).map<Map<String, dynamic>>((p) {
          return <String, dynamic>{
            'date': p['date'].toString(),
            'price': (p['price'] as num).toInt(),
            'qty': (p['qty'] as num).toInt(),
            'total': (p['total'] as num).toInt(),
          };
        }).toList();

    List<Map<String, dynamic>> hLines =
        List<Map<String, dynamic>>.from(
          data['hLines'] ?? [],
        ).map<Map<String, dynamic>>((h) {
          return <String, dynamic>{
            'price': (h['price'] as num).toInt(),
            'color': (h['color'] as num).toInt(),
          };
        }).toList();

    setState(() {
      _searchController.text = '${stockItem['Name']} ($code)';
      _currentPlans = plans;
      _hLines = hLines;
      _stopLossPrice = data['stopLoss'] != null
          ? (data['stopLoss'] as num).toInt()
          : null;
      _colorIndex = _hLines.length;
      _calculateSummary();
    });
    _searchStock(fromLoad: true);
  }

  @override
  Widget build(BuildContext context) {
    final bool isKeyboardUp = MediaQuery.of(context).viewInsets.bottom > 0;
    final double activeChartFactor = isKeyboardUp
        ? _chartHeightFactor.clamp(0.2, 0.35)
        : _chartHeightFactor;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '나만의 매수 전략(Plan Stock)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: const Color(0xFF1A5276),
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '최신 데이터 다시 불러오기',
              onPressed: () {
                if (_searchController.text.isNotEmpty) {
                  _searchStock(fromLoad: true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('최신 데이터를 불러옵니다.')),
                  );
                }
              },
            ),
          ],
        ),
        resizeToAvoidBottomInset: true,
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: Colors.grey[100],
              child: Row(
                children: [
                  Expanded(
                    child: RawAutocomplete<Map<String, String>>(
                      textEditingController: _searchController,
                      focusNode: _searchFocusNode,
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        if (textEditingValue.text.isEmpty) {
                          return const Iterable<Map<String, String>>.empty();
                        }
                        final String input = textEditingValue.text
                            .toLowerCase();
                        final String inputQwerty = _getQwerty(input);

                        return _stockList.where((stock) {
                          final String name = stock['Name']!.toLowerCase();
                          final String code = stock['Code']!.toLowerCase();
                          final String engName = stock['Qwerty'] ?? '';
                          return name.contains(input) ||
                              code.contains(input) ||
                              engName.contains(input) ||
                              name.contains(inputQwerty) ||
                              engName.contains(inputQwerty);
                        });
                      },
                      displayStringForOption: (option) =>
                          '${option['Name']} (${option['Code']})',
                      onSelected: (option) {
                        _searchController.text =
                            '${option['Name']} (${option['Code']})';
                        _searchStock();
                      },
                      fieldViewBuilder:
                          (context, controller, focusNode, onFieldSubmitted) {
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onTap: () {
                                controller.clear();
                              },
                              decoration: const InputDecoration(
                                hintText: '종목명 또는 코드 (영타 자동 인식)',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              onSubmitted: (_) {
                                onFieldSubmitted();
                                _searchStock();
                              },
                            );
                          },
                      optionsViewBuilder: (context, onSelected, options) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4.0,
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              constraints: const BoxConstraints(maxHeight: 250),
                              width: max(
                                200.0,
                                MediaQuery.of(context).size.width - 100,
                              ),
                              child: ListView.builder(
                                padding: EdgeInsets.zero,
                                shrinkWrap: true,
                                itemCount: options.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final option = options.elementAt(index);
                                  return ListTile(
                                    title: Text(
                                      '${option['Name']} (${option['Code']})',
                                    ),
                                    onTap: () => onSelected(option),
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _searchStock,
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('조회'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A5276),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: (activeChartFactor * 1000).toInt(),
              child: Stack(
                children: [
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : Column(
                          children: [
                            Expanded(
                              flex: 3,
                              child: SfCartesianChart(
                                margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                                legend: const Legend(
                                  isVisible: true,
                                  position: LegendPosition.top,
                                  alignment: ChartAlignment.center,
                                  toggleSeriesVisibility: true,
                                  iconHeight: 10,
                                  iconWidth: 10,
                                  padding: 2,
                                  itemPadding: 6,
                                ),
                                onChartTouchInteractionDown:
                                    (ChartTouchInteractionArgs args) {
                                      if (_seriesController == null) return;

                                      var point = _seriesController!
                                          .pixelToPoint(args.position);
                                      if (point.y == null) return;

                                      double touchedY = (point.y as num)
                                          .toDouble();
                                      if (touchedY.isNaN) return;

                                      double threshold = 0;
                                      if (_yAxisMax != null &&
                                          _yAxisMin != null) {
                                        threshold =
                                            (_yAxisMax! - _yAxisMin!) * 0.05;
                                      } else if (_chartData.isNotEmpty) {
                                        threshold =
                                            _chartData.last.close * 0.05;
                                      } else {
                                        threshold = 1000;
                                      }

                                      if (_stopLossPrice != null &&
                                          (_stopLossPrice! - touchedY).abs() <=
                                              threshold) {
                                        _setDragState(true, stopLoss: true);
                                        return;
                                      }

                                      for (int i = 0; i < _hLines.length; i++) {
                                        double linePrice =
                                            (_hLines[i]['price'] as num)
                                                .toDouble();
                                        if ((linePrice - touchedY).abs() <=
                                            threshold) {
                                          _setDragState(true, hLineIdx: i);
                                          return;
                                        }
                                      }
                                    },
                                // 🌟 [수정] Update가 아닌 Move로 정확한 속성명을 사용했습니다!
                                onChartTouchInteractionMove:
                                    (ChartTouchInteractionArgs args) {
                                      if (_draggedHLineIndex == null &&
                                          !_isDraggingStopLoss) {
                                        return;
                                      }
                                      if (_seriesController == null) return;

                                      var point = _seriesController!
                                          .pixelToPoint(args.position);
                                      if (point.y == null) return;

                                      double newY = (point.y as num).toDouble();
                                      if (newY.isNaN) return;

                                      setState(() {
                                        if (_draggedHLineIndex != null) {
                                          _hLines[_draggedHLineIndex!]['price'] =
                                              newY.round();
                                        } else if (_isDraggingStopLoss) {
                                          _stopLossPrice = newY.round();
                                        }
                                      });
                                    },
                                onChartTouchInteractionUp:
                                    (ChartTouchInteractionArgs args) {
                                      if (_draggedHLineIndex != null ||
                                          _isDraggingStopLoss) {
                                        _setDragState(false);
                                        _savePlansSilently();
                                      }
                                    },
                                primaryXAxis: CategoryAxis(
                                  onRendererCreated:
                                      (ChartAxisController controller) {
                                        _priceAxisController = controller;
                                      },
                                  labelStyle: const TextStyle(
                                    color: Colors.transparent,
                                    fontSize: 0,
                                  ),
                                  majorTickLines: const MajorTickLines(size: 0),
                                  axisLine: const AxisLine(width: 0),
                                  initialZoomFactor: _zoomNotifier.value[0],
                                  initialZoomPosition: _zoomNotifier.value[1],
                                ),
                                primaryYAxis: NumericAxis(
                                  minimum: _yAxisMin,
                                  maximum: _yAxisMax,
                                  opposedPosition: true,
                                  labelPosition: ChartDataLabelPosition.inside,
                                  tickPosition: TickPosition.inside,
                                  numberFormat: NumberFormat('#,###'),
                                  plotBands: <PlotBand>[
                                    if (_avgPrice > 0)
                                      PlotBand(
                                        isVisible: true,
                                        start: _avgPrice,
                                        end: _avgPrice,
                                        borderColor: Colors.black,
                                        borderWidth: 1.0,
                                        text:
                                            '평단가: ${f.format(_avgPrice.toInt())}',
                                        textStyle: const TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                        horizontalTextAlignment:
                                            TextAnchor.start,
                                        verticalTextAlignment: TextAnchor.start,
                                      ),
                                    if (_stopLossPrice != null)
                                      PlotBand(
                                        isVisible: true,
                                        start: _stopLossPrice!.toDouble(),
                                        end: _stopLossPrice!.toDouble(),
                                        borderColor: Colors.blue,
                                        borderWidth: 2.0,
                                        dashArray: const <double>[5, 5],
                                        text:
                                            '손절가: ${f.format(_stopLossPrice)}',
                                        textStyle: const TextStyle(
                                          color: Colors.blue,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                        horizontalTextAlignment:
                                            TextAnchor.start,
                                        verticalTextAlignment: TextAnchor.start,
                                      ),
                                    for (var hline in _hLines)
                                      PlotBand(
                                        isVisible: true,
                                        start: (hline['price'] as num)
                                            .toDouble(),
                                        end: (hline['price'] as num).toDouble(),
                                        borderColor: Color(
                                          hline['color'] as int,
                                        ),
                                        borderWidth: 1.5,
                                        dashArray: const <double>[4, 4],
                                        text: f.format(hline['price']),
                                        textStyle: TextStyle(
                                          color: Color(hline['color'] as int),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                        horizontalTextAlignment:
                                            TextAnchor.start,
                                        verticalTextAlignment: TextAnchor.start,
                                      ),
                                    if (_previewPrice != null)
                                      PlotBand(
                                        isVisible: true,
                                        start: _previewPrice!,
                                        end: _previewPrice!,
                                        borderColor: Colors.grey,
                                        borderWidth: 2.0,
                                        dashArray: const <double>[6, 6],
                                        text:
                                            '미리보기: ${f.format(_previewPrice!.toInt())}',
                                        textStyle: const TextStyle(
                                          color: Colors.black87,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                        horizontalTextAlignment:
                                            TextAnchor.start,
                                        verticalTextAlignment: TextAnchor.start,
                                      ),
                                  ],
                                ),
                                zoomPanBehavior: _zoomPanBehavior,
                                trackballBehavior: _trackballBehavior,
                                onTrackballPositionChanging:
                                    (TrackballArgs args) {
                                      final idx =
                                          args.chartPointInfo.dataPointIndex;
                                      if (idx == null ||
                                          idx < 0 ||
                                          idx >= _chartData.length) {
                                        return;
                                      }
                                      final d = _chartData[idx];
                                      if (d.isSuspended) return;
                                      args.chartPointInfo.label =
                                          '${d.date}\n'
                                          '시가: ${f.format(d.open.toInt())}\n'
                                          '고가: ${f.format(d.high.toInt())}\n'
                                          '저가: ${f.format(d.low.toInt())}\n'
                                          '종가: ${f.format(d.close.toInt())}';
                                    },
                                onZooming: (ZoomPanArgs args) {
                                  if (_isSyncing) return;
                                  _isSyncing = true;
                                  if (_volAxisController?.zoomFactor !=
                                      args.currentZoomFactor) {
                                    _volAxisController?.zoomFactor =
                                        args.currentZoomFactor;
                                  }
                                  if (_volAxisController?.zoomPosition !=
                                      args.currentZoomPosition) {
                                    _volAxisController?.zoomPosition =
                                        args.currentZoomPosition;
                                  }
                                  _zoomNotifier.value = [
                                    args.currentZoomFactor,
                                    args.currentZoomPosition,
                                  ];
                                  _isSyncing = false;
                                  _recalcYAxis(
                                    args.currentZoomFactor,
                                    args.currentZoomPosition,
                                  );
                                },
                                series: <CartesianSeries<ChartData, String>>[
                                  FastLineSeries<ChartData, String>(
                                    name: 'MA240',
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.ma240,
                                    color: Colors.grey[800],
                                    width: 2,
                                    animationDuration: 0,
                                    enableTooltip: false,
                                    isVisibleInLegend: true,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.drop,
                                        ),
                                  ),
                                  FastLineSeries<ChartData, String>(
                                    name: 'MA120',
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.ma120,
                                    color: Colors.green,
                                    width: 2,
                                    animationDuration: 0,
                                    enableTooltip: false,
                                    isVisibleInLegend: true,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.drop,
                                        ),
                                  ),
                                  FastLineSeries<ChartData, String>(
                                    name: 'MA60',
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.ma60,
                                    color: Colors.blue,
                                    width: 2,
                                    animationDuration: 0,
                                    enableTooltip: false,
                                    isVisibleInLegend: true,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.drop,
                                        ),
                                  ),
                                  FastLineSeries<ChartData, String>(
                                    name: 'MA20',
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.ma20,
                                    color: Colors.red,
                                    width: 2,
                                    animationDuration: 0,
                                    enableTooltip: false,
                                    isVisibleInLegend: true,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.drop,
                                        ),
                                  ),
                                  FastLineSeries<ChartData, String>(
                                    name: 'MA5',
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.ma5,
                                    color: Colors.lightGreen,
                                    width: 2,
                                    animationDuration: 0,
                                    enableTooltip: false,
                                    isVisibleInLegend: true,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.drop,
                                        ),
                                  ),
                                  LineSeries<ChartData, String>(
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) => d.suspendClose,
                                    color: Colors.grey,
                                    width: 1.5,
                                    dashArray: const <double>[4, 4],
                                    enableTooltip: false,
                                    isVisibleInLegend: false,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.gap,
                                        ),
                                  ),
                                  CandleSeries<ChartData, String>(
                                    name: 'Candle',
                                    onRendererCreated:
                                        (ChartSeriesController controller) {
                                          _seriesController = controller;
                                        },
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    lowValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.low,
                                    highValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.high,
                                    openValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.open,
                                    closeValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.close,
                                    bullColor: Colors.red,
                                    bearColor: Colors.blue,
                                    enableSolidCandles: true,
                                    isVisibleInLegend: false,
                                    emptyPointSettings:
                                        const EmptyPointSettings(
                                          mode: EmptyPointMode.gap,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: SfCartesianChart(
                                margin: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                                primaryXAxis: CategoryAxis(
                                  onRendererCreated:
                                      (ChartAxisController controller) {
                                        _volAxisController = controller;
                                      },
                                  labelIntersectAction:
                                      AxisLabelIntersectAction.hide,
                                  initialZoomFactor: _zoomNotifier.value[0],
                                  initialZoomPosition: _zoomNotifier.value[1],
                                ),
                                primaryYAxis: NumericAxis(
                                  minimum: 0,
                                  maximum: _volAxisMax,
                                  opposedPosition: true,
                                  labelPosition: ChartDataLabelPosition.inside,
                                  tickPosition: TickPosition.inside,
                                  numberFormat: NumberFormat.compact(),
                                  majorGridLines: const MajorGridLines(
                                    width: 0,
                                  ),
                                ),
                                zoomPanBehavior: _volumeZoomBehavior,
                                onZooming: (ZoomPanArgs args) {
                                  if (_isSyncing) return;
                                  _isSyncing = true;
                                  if (_priceAxisController?.zoomFactor !=
                                      args.currentZoomFactor) {
                                    _priceAxisController?.zoomFactor =
                                        args.currentZoomFactor;
                                  }
                                  if (_priceAxisController?.zoomPosition !=
                                      args.currentZoomPosition) {
                                    _priceAxisController?.zoomPosition =
                                        args.currentZoomPosition;
                                  }
                                  _zoomNotifier.value = [
                                    args.currentZoomFactor,
                                    args.currentZoomPosition,
                                  ];
                                  _isSyncing = false;
                                  _recalcYAxis(
                                    args.currentZoomFactor,
                                    args.currentZoomPosition,
                                  );
                                },
                                series: <CartesianSeries<ChartData, String>>[
                                  ColumnSeries<ChartData, String>(
                                    dataSource: _chartData,
                                    xValueMapper: (d, _) => d.date,
                                    yValueMapper: (d, _) =>
                                        d.isSuspended ? null : d.volume,
                                    animationDuration: 0,
                                    pointColorMapper: (d, _) {
                                      if (d.isSuspended) {
                                        return Colors.transparent;
                                      }
                                      if (d.close > d.open) return Colors.red;
                                      if (d.close < d.open) return Colors.blue;
                                      return Colors.grey;
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                  Positioned(
                    top: 30,
                    left: 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            iconSize: 28,
                            icon: const Icon(
                              Icons.zoom_in,
                              color: Color(0xFF1A5276),
                            ),
                            onPressed: () => _handleZoom(true),
                          ),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            iconSize: 28,
                            icon: const Icon(
                              Icons.zoom_out,
                              color: Color(0xFF1A5276),
                            ),
                            onPressed: () => _handleZoom(false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onVerticalDragUpdate: (details) {
                final totalHeight = MediaQuery.of(context).size.height;
                final double newFactor =
                    (_chartHeightFactor + details.primaryDelta! / totalHeight)
                        .clamp(0.2, 0.8);
                if (_chartHeightFactor != newFactor) {
                  setState(() {
                    _chartHeightFactor = newFactor;
                  });
                }
              },
              child: Container(
                height: 16,
                color: Colors.grey[100],
                child: Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: ((1 - activeChartFactor) * 1000).toInt(),
              child: Column(
                children: [
                  const TabBar(
                    labelColor: Color(0xFF1A5276),
                    unselectedLabelColor: Colors.grey,
                    indicatorColor: Color(0xFF1A5276),
                    tabs: [
                      Tab(icon: Icon(Icons.shopping_cart), text: "매수 계획"),
                      Tab(icon: Icon(Icons.horizontal_rule), text: "수평선 및 손절"),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.blue[50],
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Colors.blue.shade200,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    children: [
                                      Text(
                                        '총 ${f.format(_totalQty)}주',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '총 금액: ${f.format(_totalAmount)}원',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '평단: ${f.format(_avgPrice.toInt())}원',
                                        style: const TextStyle(
                                          color: Colors.blue,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    InkWell(
                                      onTap: _pickDate,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 15,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Colors.grey,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(
                                              Icons.calendar_today,
                                              size: 16,
                                              color: Colors.black54,
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              DateFormat(
                                                'yyyy-MM-dd',
                                              ).format(_selectedDate),
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: TextField(
                                        controller: _priceController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: '매수가',
                                          border: OutlineInputBorder(),
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: TextField(
                                        controller: _qtyController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: '수량',
                                          border: OutlineInputBorder(),
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _addPlan,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF27AE60,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 10,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text('추가'),
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _modifyPlan,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF2980B9,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 10,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text('수정'),
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _resetAllData,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF7F8C8D,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 10,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text('초기화'),
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _savePlans,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFF8E44AD,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 10,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text('저장'),
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: _showLoadDialog,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(
                                            0xFFE67E22,
                                          ),
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 10,
                                          ),
                                          minimumSize: Size.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        child: const Text('불러오기'),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Container(
                                  color: Colors.grey[200],
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                    horizontal: 4,
                                  ),
                                  child: const Row(
                                    children: [
                                      Expanded(
                                        flex: 3,
                                        child: Text(
                                          '날짜',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          '매수가',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 1,
                                        child: Text(
                                          '수량',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        flex: 2,
                                        child: Text(
                                          '총액',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: 30),
                                    ],
                                  ),
                                ),
                                ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _currentPlans.length,
                                  itemBuilder: (context, index) {
                                    final plan = _currentPlans[index];
                                    final bool isSelected =
                                        index == _selectedPlanIndex;
                                    return GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _selectedPlanIndex = index;
                                          _selectedDate = DateFormat(
                                            'yyyy-MM-dd',
                                          ).parse(plan['date']);
                                          _priceController.text = plan['price']
                                              .toString();
                                          _qtyController.text = plan['qty']
                                              .toString();
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                          horizontal: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? Colors.blue.withValues(
                                                  alpha: 0.1,
                                                )
                                              : Colors.transparent,
                                          border: const Border(
                                            bottom: BorderSide(
                                              color: Colors.black12,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              flex: 3,
                                              child: Text(plan['date']),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: Text(
                                                f.format(plan['price']),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 1,
                                              child: Text(
                                                f.format(plan['qty']),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 2,
                                              child: Text(
                                                f.format(plan['total']),
                                                style: const TextStyle(
                                                  color: Colors.blue,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.red,
                                                size: 20,
                                              ),
                                              onPressed: () =>
                                                  _deletePlan(index),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(10.0),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '📉 손절라인 설정',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _stopLossController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: '손절가 (원)',
                                          border: OutlineInputBorder(),
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    ElevatedButton(
                                      onPressed: _setStopLoss,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF3498DB,
                                        ),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                      ),
                                      child: const Text('설정'),
                                    ),
                                    const SizedBox(width: 5),
                                    ElevatedButton(
                                      onPressed: _clearStopLoss,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFFE74C3C,
                                        ),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                      ),
                                      child: const Text('해제'),
                                    ),
                                  ],
                                ),
                                const Divider(height: 30, thickness: 1),
                                const Text(
                                  '📐 수평선 관리 (선 터치하여 직접 드래그 가능!)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _hlineController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: '수평선 가격 (원)',
                                          border: OutlineInputBorder(),
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 5),
                                    ElevatedButton(
                                      onPressed: _addHLine,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF2ECC71,
                                        ),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                      ),
                                      child: const Text('추가'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  color: Colors.grey[200],
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                    horizontal: 8,
                                  ),
                                  child: const Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '수평선 가격',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '삭제',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      SizedBox(width: 10),
                                    ],
                                  ),
                                ),
                                ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _hLines.length,
                                  itemBuilder: (context, index) {
                                    return InkWell(
                                      onTap: () => _editHLinePrice(index),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                          horizontal: 8,
                                        ),
                                        decoration: const BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: Colors.black12,
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(
                                                  Icons.circle,
                                                  color: Color(
                                                    _hLines[index]['color']
                                                        as int,
                                                  ),
                                                  size: 14,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '${f.format(_hLines[index]['price'])} 원',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 15,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete,
                                                color: Colors.red,
                                                size: 20,
                                              ),
                                              onPressed: () =>
                                                  _deleteHLine(index),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getQwerty(String text) {
    const List<String> cho = [
      'r',
      'R',
      's',
      'e',
      'E',
      'f',
      'a',
      'q',
      'Q',
      't',
      'T',
      'd',
      'w',
      'W',
      'c',
      'z',
      'x',
      'v',
      'g',
    ];
    const List<String> jung = [
      'k',
      'o',
      'i',
      'O',
      'j',
      'p',
      'u',
      'P',
      'h',
      'hk',
      'ho',
      'hl',
      'y',
      'n',
      'nj',
      'np',
      'nl',
      'b',
      'm',
      'ml',
      'l',
    ];
    const List<String> jong = [
      '',
      'r',
      'R',
      'rt',
      's',
      'sw',
      'sg',
      'e',
      'f',
      'fr',
      'fa',
      'fq',
      'ft',
      'fx',
      'fv',
      'fg',
      'a',
      'q',
      'qt',
      't',
      'T',
      'd',
      'w',
      'c',
      'z',
      'x',
      'v',
      'g',
    ];
    final Map<String, String> jamoToEng = {
      'ㄱ': 'r',
      'ㄲ': 'R',
      'ㄳ': 'rt',
      'ㄴ': 's',
      'ㄵ': 'sw',
      'ㄶ': 'sg',
      'ㄷ': 'e',
      'ㄸ': 'E',
      'ㄹ': 'f',
      'ㄺ': 'fr',
      'ㄻ': 'fa',
      'ㄼ': 'fq',
      'ㄽ': 'ft',
      'ㄾ': 'fx',
      'ㄿ': 'fv',
      'ㅀ': 'fg',
      'ㅁ': 'a',
      'ㅂ': 'q',
      'ㅃ': 'Q',
      'ㅄ': 'qt',
      'ㅅ': 't',
      'ㅆ': 'T',
      'ㅇ': 'd',
      'ㅈ': 'w',
      'ㅉ': 'W',
      'ㅊ': 'c',
      'ㅋ': 'z',
      'ㅌ': 'x',
      'ㅍ': 'v',
      'ㅎ': 'g',
      'ㅏ': 'k',
      'ㅐ': 'o',
      'ㅑ': 'i',
      'ㅒ': 'O',
      'ㅓ': 'j',
      'ㅔ': 'p',
      'ㅕ': 'u',
      'ㅖ': 'P',
      'ㅗ': 'h',
      'ㅘ': 'hk',
      'ㅙ': 'ho',
      'ㅚ': 'hl',
      'ㅛ': 'y',
      'ㅜ': 'n',
      'ㅝ': 'nj',
      'ㅞ': 'np',
      'ㅟ': 'nl',
      'ㅠ': 'b',
      'ㅡ': 'm',
      'ㅢ': 'ml',
      'ㅣ': 'l',
    };

    String result = '';
    for (int i = 0; i < text.length; i++) {
      int code = text.codeUnitAt(i);
      if (code >= 0xAC00 && code <= 0xD7A3) {
        int index = code - 0xAC00;
        int choIdx = index ~/ 588;
        int jungIdx = (index % 588) ~/ 28;
        int jongIdx = (index % 588) % 28;
        result += cho[choIdx] + jung[jungIdx] + jong[jongIdx];
      } else if (code >= 0x3131 && code <= 0x3163) {
        result += jamoToEng[text[i]] ?? text[i];
      } else {
        result += text[i];
      }
    }
    return result.toLowerCase();
  }
}

class ChartData {
  ChartData(
    this.date,
    this.open,
    this.high,
    this.low,
    this.close,
    this.volume,
    this.ma5,
    this.ma20,
    this.ma60,
    this.ma120,
    this.ma240, {
    this.isSuspended = false,
    this.suspendClose,
  });
  final String date;
  final double open;
  final double high;
  final double low;
  final double close;
  final int volume;
  final double? ma5;
  final double? ma20;
  final double? ma60;
  final double? ma120;
  final double? ma240;

  bool isSuspended;
  double? suspendClose;
}
