package com.gmx.utils;

import java.io.File;

/**
 * Created by MingXing on 16/4/7.
 *
 * Log工具
 *
 * <p/>
 * implements https://github.com/ZhaoKaiQiang/KLog
 */
public class GLog {

    /**
     * 初始化
     *
     * @param isShowLog
     */
    public static void init(boolean isShowLog) {
        com.socks.library.KLog.init(isShowLog);
    }

    public static void v(Object msg) {
        com.socks.library.KLog.v(msg);
    }

    public static void v(String tag, Object... objects) {
        com.socks.library.KLog.v(tag, objects);
    }

    public static void d() {
        com.socks.library.KLog.d();
    }

    public static void d(Object msg) {
        com.socks.library.KLog.d(msg);
    }

    public static void d(String tag, Object... objects) {
        com.socks.library.KLog.d(tag, objects);
    }

    public static void i() {
        com.socks.library.KLog.i();
    }

    public static void i(Object msg) {
        com.socks.library.KLog.i(msg);
    }

    public static void i(String tag, Object... objects) {
        com.socks.library.KLog.i(tag, objects);
    }

    public static void w() {
        com.socks.library.KLog.w();
    }

    public void w(Object msg) {
        com.socks.library.KLog.w(msg);
    }

    public static void w(String tag, Object... objects) {
        com.socks.library.KLog.w(tag, objects);
    }

    public void e() {
        com.socks.library.KLog.e();
    }

    public static void e(Object msg) {
        com.socks.library.KLog.e(msg);
    }

    public static void e(String tag, Object... objects) {
        com.socks.library.KLog.e(tag, objects);
    }

    public static void a() {
        com.socks.library.KLog.a();
    }

    public static void a(Object msg) {
        com.socks.library.KLog.a(msg);
    }

    public static void a(String tag, Object... objects) {
        com.socks.library.KLog.a(tag, objects);
    }

    public static void json(String jsonFormat) {
        com.socks.library.KLog.json(jsonFormat);
    }

    public static void json(String tag, String jsonFormat) {
        com.socks.library.KLog.json(tag, jsonFormat);
    }

    public static void xml(String xml) {
        com.socks.library.KLog.xml(xml);
    }

    public static void xml(String tag, String xml) {
        com.socks.library.KLog.xml(tag, xml);
    }

    public static void file(File targetDirectory, Object msg) {
        com.socks.library.KLog.file(targetDirectory, msg);
    }

    public static void file(String tag, File targetDirectory, Object msg) {
        com.socks.library.KLog.file(tag, targetDirectory, msg);
    }

    public static void file(String tag, File targetDirectory, String fileName, Object msg) {
        com.socks.library.KLog.file(tag, targetDirectory, fileName, msg);
    }
}
