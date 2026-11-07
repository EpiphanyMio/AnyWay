# AnyWay

AnyWay �� Mac �� Windows �����涨λģ���������� JSON ���ø�ʽ��`schemaVersion: 1`��������֧�ֵ��㡢·����Լ 400 ���ܵ�ģ�壻�ѻ���·������϶�������Mac ��֧�� iOS ģ������ʵ�� iPhone��Windows ��֧��ʵ�� iPhone�����˾������� Android ʵ���豸��Windows �˻�֧�� HarmonyOS 7+ �� hdc/testhelper��

## �ֿ�ṹ

- `mac/`��SwiftUI/MapKit Ӧ�á�Mac Android ���׹��̺� `.pkg` �����ű���
- `windows/`��PySide6/Leaflet Ӧ�á�Windows Android ���׹��̺� `.exe` ��װ���ű���
- `VERSION`����������Ӧ�ú����� App ��ͳһ�汾�š��޸İ汾ʱֻ�༭���ļ���
- `scripts/check_versions.py` �� `.github/workflows/ci.yml`����ƽ̨�汾�빹����顣

Mac ���к��豸���Ӳ���� [mac/README.md](mac/README.md)��Windows ����� [windows/README.md](windows/README.md)��

## ����

- Mac���� `mac/` ִ�� `bash scripts/build-app.sh`��Apple Silicon ��װ��ִ�� `bash scripts/build-pkg.sh`��
- Windows���� `windows/` ִ�� `powershell -ExecutionPolicy Bypass -File scripts\build.ps1`��Ȼ���Ը�Ŀ¼ `VERSION` ��ֵ���� `packaging/windows.iss`��

ÿ���޸Ĺ��ù��ܡ����ø�ʽ��汾��ʱ���������ƽ̨��ʵ����˵���������ж�Ӧ���ԡ��ֿ� CI �ֱ�ִ�� Swift �� Python ���ԡ���������Ӧ�á�
