#### Library
2016.4.7
添加打印Log  [第三方](https://github.com/ZhaoKaiQiang/KLog)
如何使用: 在Application onCreate()中定义. 可控制Log是否输出, 默认true
```
@Override
public void onCreate() {
    //...
    KLog.init(BuildConfig.DEBUG);
    //...
    // 使用
    KLog.a();
    KLog.e();
    //...
}
```

