package com.gmx.log;

import java.io.File;

/**
 * Created by MingXing on 16/4/7.
 * <p/>
 * implements https://github.com/ZhaoKaiQiang/KLog
 */
public class KLog implements IKLog {

    /**
     * 初始化
     *
     * @param isShowLog
     */
    public static void init(boolean isShowLog) {
        com.socks.library.KLog.init(isShowLog);
    }


    @Override
    public void v(Object msg) {
        com.socks.library.KLog.v(msg);
    }

    @Override
    public void v(String tag, Object... objects) {
        com.socks.library.KLog.v(tag, objects);
    }

    @Override
    public void d() {
        com.socks.library.KLog.d();
    }

    @Override
    public void d(Object msg) {
        com.socks.library.KLog.d(msg);
    }

    @Override
    public void d(String tag, Object... objects) {
        com.socks.library.KLog.d(tag, objects);
    }

    @Override
    public void i() {
        com.socks.library.KLog.i();
    }

    @Override
    public void i(Object msg) {
        com.socks.library.KLog.i(msg);
    }

    @Override
    public void i(String tag, Object... objects) {
        com.socks.library.KLog.i(tag, objects);
    }

    @Override
    public void w() {
        com.socks.library.KLog.w();
    }

    @Override
    public void w(Object msg) {
        com.socks.library.KLog.w(msg);
    }

    @Override
    public void w(String tag, Object... objects) {
        com.socks.library.KLog.w(tag, objects);
    }

    @Override
    public void e() {
        com.socks.library.KLog.e();
    }

    @Override
    public void e(Object msg) {
        com.socks.library.KLog.e(msg);
    }

    @Override
    public void e(String tag, Object... objects) {
        com.socks.library.KLog.e(tag, objects);
    }

    @Override
    public void a() {
        com.socks.library.KLog.a();
    }

    @Override
    public void a(Object msg) {
        com.socks.library.KLog.a(msg);
    }

    @Override
    public void a(String tag, Object... objects) {
        com.socks.library.KLog.a(tag, objects);
    }

    @Override
    public void json(String jsonFormat) {
        com.socks.library.KLog.json(jsonFormat);
    }

    @Override
    public void json(String tag, String jsonFormat) {
        com.socks.library.KLog.json(tag, jsonFormat);
    }

    @Override
    public void xml(String xml) {
        com.socks.library.KLog.xml(xml);
    }

    @Override
    public void xml(String tag, String xml) {
        com.socks.library.KLog.xml(tag, xml);
    }

    @Override
    public void file(File targetDirectory, Object msg) {
        com.socks.library.KLog.file(targetDirectory, msg);
    }

    @Override
    public void file(String tag, File targetDirectory, Object msg) {
        com.socks.library.KLog.file(tag, targetDirectory, msg);
    }

    @Override
    public void file(String tag, File targetDirectory, String fileName, Object msg) {
        com.socks.library.KLog.file(tag, targetDirectory, fileName, msg);
    }
}
