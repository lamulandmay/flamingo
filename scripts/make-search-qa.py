#!/usr/bin/env python3
"""Disposable mixed-format, unorganized retrieval fixtures. Never touches personal files."""
from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET
import shutil

root = Path(__file__).resolve().parents[1]
out = root / 'build' / 'Unified Search QA'
for directory in ['Projects/Research Lab', 'Downloads', 'Old work', '散乱的笔记', 'Empty folder']:
    (out / directory).mkdir(parents=True, exist_ok=True)
ns = {'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}

def deck(destination, amount):
    with ZipFile(root / 'fixtures/vault/decks/q3-board-review.pptx') as src, ZipFile(destination, 'w') as dst:
        for item in src.infolist():
            data = src.read(item.filename)
            if item.filename == 'ppt/slides/slide7.xml':
                xml = ET.fromstring(data)
                strings = xml.findall('.//a:t', ns)
                for index, node in enumerate(strings):
                    node.text = ('Orchid revised budget' if index == 0 else
                                 f'ORCHIDSEARCH{amount} equipment budget. The Orchid project measured equipment expenditure across twelve laboratory groups during the spring term. Each group recorded purchase dates, supplier invoices, instrument categories, and delivery locations.')
                data = ET.tostring(xml, encoding='utf-8', xml_declaration=True)
            dst.writestr(item, data)

selected = out / 'Projects/Research Lab/Orchid budget v3.pptx'
deck(selected, '28400')
deck(out / 'Old work/Orchid budget final v2.pptx', '27100')
shutil.copy2(selected, out / 'Downloads/98172.pptx')
shutil.copy2(root / 'fixtures/vault/docs/pricing-memo.docx', out / 'Projects/Research Lab/Pricing memo.docx')
shutil.copy2(root / 'fixtures/vault/finance/q3-model.xlsx', out / 'Downloads/Budget data.xlsx')
shutil.copy2(root / 'fixtures/vault/design/arc-render.png', out / 'Downloads/image001.png')
(out / '散乱的笔记/未命名.txt').write_text('第一行\n普通的笔记\n\n定价策略 ORCHIDTEXT28400\nLast line\n')

# Small real two-page PDF, with the exact-search term only on page 2.
pages = ['Orchid research overview', 'ORCHIDPDF28400 Equipment budget revised to 28400.']
objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>']
for i, content in enumerate(pages):
    stream = ('BT /F1 20 Tf 50 720 Td (' + content + ') Tj ET').encode()
    objects.append(f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 7 0 R >> >> /Contents {4 + i * 2} 0 R >>'.encode())
    objects.append(b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream')
objects.append(b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
pdf = bytearray(b'%PDF-1.4\n')
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf)); pdf += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
xref = len(pdf)
pdf += f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
for offset in offsets[1:]: pdf += f'{offset:010d} 00000 n \n'.encode()
pdf += f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
(out / 'Downloads/Orchid budget.pdf').write_bytes(pdf)
print(out)
