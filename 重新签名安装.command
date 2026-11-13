#!/bin/zsh
cd -- "${0:A:h}" || exit 1
print '人生记录 · 重新签名并覆盖安装到你的 iPhone'
print '请先解锁手机，靠近这台 Mac；如能使用数据线，连接通常更稳定。'
print '此脚本不卸载 App、不删除记录、不购买开发者会员。'
/usr/bin/env python3 Scripts/resign_install.py "$@"
result=$?
print ''
if [[ $result -eq 0 ]]; then
  print '处理完成。按回车关闭窗口。'
else
  print '没有完成，请保留上方提示。按回车关闭窗口。'
fi
read -r reply
exit $result
