import 'package:flutter_test/flutter_test.dart';
import 'package:time_manager/models/category.dart';
import 'package:time_manager/models/schedule_template.dart';
import 'package:time_manager/models/target.dart';
import 'package:time_manager/services/category_document_merge.dart';

void main() {
  group('Target.fromJson 宽松解析', () {
    test('数字字段是字符串时仍能解析，不抛异常', () {
      final target = Target.fromJson({
        'id': 12345,
        'name': '运动',
        'type': '1',
        'color': '4278190080',
        'period': '每天',
        'frequencyCount': '3',
        'durationHours': '6',
        'updatedAt': '1700000000000',
      });

      expect(target.id, '12345');
      expect(target.type, TargetType.timePoint);
      expect(target.frequencyCount, 3);
      expect(target.durationHours, 6.0);
      expect(target.updatedAt, 1700000000000);
    });

    test('数字字段是 double 时取整而不是丢弃整条目标', () {
      final target = Target.fromJson({
        'id': 'a1',
        'name': '读书',
        'type': 2.0,
        'color': 4278190080.0,
        'frequencyCount': 3.0,
      });

      expect(target.id, 'a1');
      expect(target.type, TargetType.frequency);
      expect(target.frequencyCount, 3);
    });

    test('缺失 / 非法字段回退默认值', () {
      final target = Target.fromJson({'type': 'abc', 'frequencyCount': null});

      expect(target.type, TargetType.duration);
      expect(target.frequencyCount, 0);
      expect(target.name, '');
    });
  });

  group('Category.fromJson 宽松解析', () {
    test('子事件列表混入非字符串项时只保留字符串项', () {
      final category = Category.fromJson({
        'id': 999,
        'name': '工作',
        'color': 4278190080,
        'subCategories': ['开会', 42, null, '写文档'],
        'hiddenSubCategories': [1, 2],
      });

      expect(category.id, '999');
      expect(category.subCategories, ['开会', '写文档']);
      expect(category.hiddenSubCategories, isEmpty);
    });

    test('子事件字段不是列表时返回空列表而不是抛异常', () {
      final category = Category.fromJson({
        'id': 'c1',
        'name': '生活',
        'subCategories': 'not-a-list',
      });

      expect(category.subCategories, isEmpty);
    });
  });

  group('ScheduleTemplate.fromJson 逐条容错', () {
    test('单个坏槽位不影响其余槽位与整条模板', () {
      final template = ScheduleTemplate.fromJson({
        'id': 't1',
        'name': '工作日',
        'createdAt': 1700000000000,
        'slots': [
          {'i': 0, 'l': '通勤', 'cid': 'c1'},
          'not-a-map',
          {'i': '1', 'l': '工作', 'c': '4278190080'},
        ],
      });

      expect(template.id, 't1');
      expect(template.slots.length, 2);
      expect(template.slots[0].label, '通勤');
      expect(template.slots[1].index, 1);
      expect(template.slots[1].label, '工作');
    });

    test('slots 字段不是列表时返回空列表', () {
      final template = ScheduleTemplate.fromJson({
        'id': 't2',
        'name': '空模板',
        'slots': 42,
      });

      expect(template.slots, isEmpty);
    });
  });

  group('isCategoryDocumentPayload', () {
    test('结构合法时返回 true（即使分类为空）', () {
      expect(
        isCategoryDocumentPayload('{"updated_at":1,"categories":[]}'),
        isTrue,
      );
    });

    test('坏格式 / 空内容返回 false', () {
      expect(isCategoryDocumentPayload(null), isFalse);
      expect(isCategoryDocumentPayload('   '), isFalse);
      expect(isCategoryDocumentPayload('not json'), isFalse);
      expect(isCategoryDocumentPayload('[1,2,3]'), isFalse);
      expect(isCategoryDocumentPayload('{"updated_at":1}'), isFalse);
    });

    test('坏格式不会被误判为"远端没有分类"', () {
      // parseCategoryDocument 对坏格式返回空文档，两者必须能区分，
      // 否则同步会把空文档推回远端覆盖对方数据。
      const broken = '{"categories":';
      expect(parseCategoryDocument(broken).categories, isEmpty);
      expect(isCategoryDocumentPayload(broken), isFalse);
    });
  });
}
