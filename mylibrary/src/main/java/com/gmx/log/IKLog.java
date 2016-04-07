package com.gmx.log;

import java.io.File;

/**
 * Created by MingXing on 16/4/7.
 */
public interface IKLog {

    void v(Object msg);

    void v(String tag, Object... objects);

    void d();

    void d(Object msg);

    void d(String tag, Object... objects);

    void i();

    void i(Object msg);

    void i(String tag, Object... objects);

    void w();

    void w(Object msg);

    void w(String tag, Object... objects);

    void e();

    void e(Object msg);

    void e(String tag, Object... objects);

    void a();

    void a(Object msg);

    void a(String tag, Object... objects);

    void json(String jsonFormat);

    void json(String tag, String jsonFormat);

    void xml(String xml);

    void xml(String tag, String xml);

    void file(File targetDirectory, Object msg);

    void file(String tag, File targetDirectory, Object msg);

    void file(String tag, File targetDirectory, String fileName, Object msg);
}
