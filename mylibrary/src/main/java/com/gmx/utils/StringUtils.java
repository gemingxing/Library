package com.gmx.utils;

import android.text.TextUtils;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Created by MingXing on 16/4/7.
 * <p/>
 * 字符串操作
 */
public class StringUtils {


    /**
     * 判断字符串为空
     *
     * @param srcString
     * @return
     */
    public static boolean isEmpty(String srcString) {
        if (TextUtils.isEmpty(srcString)) {
            if (srcString.trim().length() <= 0) {
                return true;
            }
        }
        return false;
    }


    /**
     * 去除字符串中空格
     *
     * @return
     */
    public static String trimString(String srcString) {
        Pattern p = Pattern.compile("\\s{2,}|\t|\r|\n");
        Matcher m = p.matcher(srcString);
        return m.replaceAll("");
    }


}
