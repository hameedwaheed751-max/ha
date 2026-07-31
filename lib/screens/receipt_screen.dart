import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models.dart';

class ReceiptScreen extends StatefulWidget {
  final Subscriber subscriber;
  final InvoiceRecord? invoice;
  const ReceiptScreen({super.key, required this.subscriber, this.invoice});

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  int? receiptNumber;

  Subscriber get subscriber => widget.subscriber;

  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String get receiptNo =>
      receiptNumber == null ? '...' : receiptNumber!.toString().padLeft(6, '0');

    bool get hasBoundInvoice => widget.invoice != null;

    DateTime get receiptDate => widget.invoice?.at ?? DateTime.now();

    String get invoiceMonthKey =>
      widget.invoice?.monthKey.isNotEmpty == true
        ? widget.invoice!.monthKey
        : Subscriber.monthKeyOf(receiptDate);

  String get issuedAt {
    final d = receiptDate;
    final date = fmt(d);
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  @override
  void initState() {
    super.initState();
    _issueNumber();
  }

  Future<void> _issueNumber() async {
    if (hasBoundInvoice) {
      if (mounted) setState(() => receiptNumber = widget.invoice!.receiptNumber);
      return;
    }
    final n = await AppStore.issueReceiptNumber();
    if (mounted) setState(() => receiptNumber = n);
  }

  Future<Uint8List> buildPdf() async {
    if (receiptNumber == null && !hasBoundInvoice) {
      receiptNumber = await AppStore.issueReceiptNumber();
    }

    final doc = pw.Document();
    final font = await PdfGoogleFonts.notoKufiArabicRegular();
    final bold = await PdfGoogleFonts.notoKufiArabicBold();
    pw.MemoryImage? logo;

    if (AppStore.officeLogoBase64.isNotEmpty) {
      try {
        logo = pw.MemoryImage(base64Decode(AppStore.officeLogoBase64));
      } catch (_) {}
    }

    final rows = <String, String>{
      'اسم المشترك': subscriber.name,
      'اليوزر': subscriber.user,
      'رقم الهاتف': subscriber.phone,
      'الباقة': subscriber.type,
      if (widget.invoice != null)
        'مبلغ الفاتورة': widget.invoice!.amount.toStringAsFixed(0),
      'مبلغ الاشتراك': subscriber.price.toStringAsFixed(0),
      'الواصل': subscriber.paid.toStringAsFixed(0),
      'المتبقي': subscriber.remaining.toStringAsFixed(0),
      if (widget.invoice != null)
        'الشهر المحاسبي': invoiceMonthKey,
      'تاريخ التفعيل': fmt(subscriber.startDate),
      'تاريخ التسديد':
          subscriber.paymentDate.isEmpty ? 'غير محدد' : subscriber.paymentDate,
      'تاريخ الانتهاء': fmt(subscriber.endDate),
      if (subscriber.payments.isNotEmpty)
        'آخر دفعة': subscriber.payments.last.amount.toStringAsFixed(0),
      'تاريخ إصدار الوصل': issuedAt,
    };

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80,
        margin: const pw.EdgeInsets.all(14),
        build: (_) => pw.Directionality(
          textDirection: pw.TextDirection.rtl,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              if (logo != null)
                pw.Center(
                  child: pw.Image(
                    logo,
                    width: 58,
                    height: 58,
                    fit: pw.BoxFit.contain,
                  ),
                ),
              pw.SizedBox(height: 5),
              pw.Text(
                AppStore.officeName,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(font: bold, fontSize: 16),
              ),
              if (AppStore.officePhone.isNotEmpty)
                pw.Text(
                  'هاتف المكتب: ${AppStore.officePhone}',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(font: font, fontSize: 9),
                ),
              if (AppStore.officeAddress.isNotEmpty)
                pw.Text(
                  AppStore.officeAddress,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(font: font, fontSize: 9),
                ),
              pw.Divider(),
              pw.Text(
                'وصل استلام',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(font: bold, fontSize: 13),
              ),
              pw.Text(
                'رقم الوصل: $receiptNo',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(font: bold, fontSize: 10),
              ),
              pw.SizedBox(height: 6),
              ...rows.entries.map(
                (e) => pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 3),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Expanded(
                        child: pw.Text(
                          e.value,
                          style: pw.TextStyle(font: font, fontSize: 9),
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Text(
                        e.key,
                        style: pw.TextStyle(font: bold, fontSize: 9),
                      ),
                    ],
                  ),
                ),
              ),
              pw.Divider(),
              pw.Text(
                AppStore.receiptFooter,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(font: font, fontSize: 8),
              ),
            ],
          ),
        ),
      ),
    );

    return doc.save();
  }

  Future<void> printReceipt() async {
    await Printing.layoutPdf(onLayout: (_) => buildPdf());
  }

  Future<void> shareReceipt() async {
    final bytes = await buildPdf();
    await Printing.sharePdf(bytes: bytes, filename: 'receipt_$receiptNo.pdf');
  }

  Widget row(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(a, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            Flexible(child: Text(b)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('وصل الاستلام'), centerTitle: true),
          body: ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      if (AppStore.officeLogoBase64.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.memory(
                            base64Decode(AppStore.officeLogoBase64),
                            width: 76,
                            height: 76,
                            fit: BoxFit.contain,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        AppStore.officeName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (AppStore.officePhone.isNotEmpty)
                        Text('هاتف المكتب: ${AppStore.officePhone}'),
                      if (AppStore.officeAddress.isNotEmpty)
                        Text(AppStore.officeAddress),
                      const Divider(height: 28),
                      const Text(
                        'وصل استلام',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'رقم الوصل: $receiptNo',
                          style: TextStyle(
                          color: Colors.grey.shade700,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      ),
                      const SizedBox(height: 12),
                      row('اسم المشترك', subscriber.name),
                      row('اليوزر', subscriber.user),
                      row('رقم الهاتف', subscriber.phone),
                      row('الباقة', subscriber.type),
                      if (widget.invoice != null)
                        row('مبلغ الفاتورة', widget.invoice!.amount.toStringAsFixed(0)),
                      row('مبلغ الاشتراك', subscriber.price.toStringAsFixed(0)),
                      row('الواصل', subscriber.paid.toStringAsFixed(0)),
                      row('المتبقي', subscriber.remaining.toStringAsFixed(0)),
                      if (widget.invoice != null)
                        row('الشهر المحاسبي', invoiceMonthKey),
                      row('تاريخ التفعيل', fmt(subscriber.startDate)),
                      row(
                        'تاريخ التسديد',
                        subscriber.paymentDate.isEmpty
                            ? 'غير محدد'
                            : subscriber.paymentDate,
                      ),
                      row('تاريخ الانتهاء', fmt(subscriber.endDate)),
                      row('تاريخ إصدار الوصل', issuedAt),
                      const Divider(height: 28),
                      Text(AppStore.receiptFooter, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: receiptNumber == null ? null : printReceipt,
                  icon: const Icon(Icons.print),
                  label: const Text('طباعة الوصل / حفظ PDF'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: receiptNumber == null ? null : shareReceipt,
                  icon: const Icon(Icons.share),
                  label: const Text('مشاركة الوصل'),
                ),
              ),
            ],
          ),
        ),
      );
}
