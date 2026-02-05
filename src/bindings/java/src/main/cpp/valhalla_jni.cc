#include <jni.h>
#include <string>
#include <memory>
#include <stdexcept>

#include "baldr/rapidjson_utils.h"
#include "config.h"
#include "midgard/logging.h"
#include "midgard/util.h"
#include "tyr/actor.h"

#include <boost/property_tree/ptree.hpp>

namespace vt = valhalla::tyr;

namespace {

/**
 * Configures Valhalla from a JSON configuration string.
 *
 * @param config JSON configuration string
 * @return Parsed configuration property tree
 * @throws std::runtime_error if parsing fails
 */
const boost::property_tree::ptree configure(const std::string& config) {
    boost::property_tree::ptree pt;
    try {
        // Parse the config and configure logging
        rapidjson::read_json(config, pt);

        auto logging_subtree = pt.get_child_optional("mjolnir.logging");
        if (logging_subtree) {
            auto logging_config =
                valhalla::midgard::ToMap<const boost::property_tree::ptree&,
                                         std::unordered_map<std::string, std::string>>(
                    logging_subtree.get());
            valhalla::midgard::logging::Configure(logging_config);
        }
    } catch (const std::exception& e) {
        throw std::runtime_error(std::string("Failed to load config: ") + e.what());
    } catch (...) {
        throw std::runtime_error("Failed to load config: unknown exception");
    }

    return pt;
}

/**
 * Throws a Java exception from C++.
 *
 * @param env JNI environment
 * @param exception_class Exception class name
 * @param message Exception message
 */
void throwJavaException(JNIEnv* env, const char* exception_class, const char* message) {
    jclass exClass = env->FindClass(exception_class);
    if (exClass != nullptr) {
        env->ThrowNew(exClass, message);
        env->DeleteLocalRef(exClass);
    }
}

/**
 * Converts a Java string to C++ std::string.
 *
 * @param env JNI environment
 * @param jstr Java string
 * @return C++ string
 */
std::string jstring_to_string(JNIEnv* env, jstring jstr) {
    if (jstr == nullptr) {
        return "";
    }

    const char* chars = env->GetStringUTFChars(jstr, nullptr);
    if (chars == nullptr) {
        return "";
    }

    std::string result(chars);
    env->ReleaseStringUTFChars(jstr, chars);
    return result;
}

/**
 * Converts a C++ std::string to Java string.
 *
 * @param env JNI environment
 * @param str C++ string
 * @return Java string
 */
jstring string_to_jstring(JNIEnv* env, const std::string& str) {
    return env->NewStringUTF(str.c_str());
}

/**
 * Converts actor pointer to jlong handle.
 *
 * @param actor Pointer to actor
 * @return Handle as jlong
 */
jlong actor_to_handle(vt::actor_t* actor) {
    return reinterpret_cast<jlong>(actor);
}

/**
 * Converts jlong handle to actor pointer.
 *
 * @param handle Handle as jlong
 * @return Pointer to actor
 */
vt::actor_t* handle_to_actor(jlong handle) {
    return reinterpret_cast<vt::actor_t*>(handle);
}

} // namespace

extern "C" {

/**
 * Creates a new Valhalla actor.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeCreate
 * Signature: (Ljava/lang/String;)J
 */
JNIEXPORT jlong JNICALL Java_global_tada_valhalla_Actor_nativeCreate(JNIEnv* env,
                                                                       jobject /* obj */,
                                                                       jstring config_str) {
    try {
        std::string config = jstring_to_string(env, config_str);
        auto pt = configure(config);

        // Create actor on heap
        vt::actor_t* actor = new vt::actor_t(pt, true);

        return actor_to_handle(actor);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return 0;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error creating actor");
        return 0;
    }
}

/**
 * Destroys a Valhalla actor.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeDestroy
 * Signature: (J)V
 */
JNIEXPORT void JNICALL Java_global_tada_valhalla_Actor_nativeDestroy(JNIEnv* /* env */,
                                                                       jobject /* obj */,
                                                                       jlong handle) {
    if (handle != 0) {
        vt::actor_t* actor = handle_to_actor(handle);
        delete actor;
    }
}

/**
 * Calculates a route.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeRoute
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeRoute(JNIEnv* env,
                                                                        jobject /* obj */,
                                                                        jlong handle,
                                                                        jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->route(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in route");
        return nullptr;
    }
}

/**
 * Locates nodes and edges.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeLocate
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeLocate(JNIEnv* env,
                                                                         jobject /* obj */,
                                                                         jlong handle,
                                                                         jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->locate(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in locate");
        return nullptr;
    }
}

/**
 * Calculates optimized route.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeOptimizedRoute
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeOptimizedRoute(
    JNIEnv* env, jobject /* obj */, jlong handle, jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->optimized_route(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in optimized_route");
        return nullptr;
    }
}

/**
 * Computes matrix.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeMatrix
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeMatrix(JNIEnv* env,
                                                                         jobject /* obj */,
                                                                         jlong handle,
                                                                         jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->matrix(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in matrix");
        return nullptr;
    }
}

/**
 * Calculates isochrones.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeIsochrone
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeIsochrone(JNIEnv* env,
                                                                            jobject /* obj */,
                                                                            jlong handle,
                                                                            jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->isochrone(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in isochrone");
        return nullptr;
    }
}

/**
 * Performs trace routing.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeTraceRoute
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeTraceRoute(
    JNIEnv* env, jobject /* obj */, jlong handle, jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->trace_route(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in trace_route");
        return nullptr;
    }
}

/**
 * Calculates trace attributes.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeTraceAttributes
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeTraceAttributes(
    JNIEnv* env, jobject /* obj */, jlong handle, jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->trace_attributes(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in trace_attributes");
        return nullptr;
    }
}

/**
 * Provides height information.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeHeight
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeHeight(JNIEnv* env,
                                                                         jobject /* obj */,
                                                                         jlong handle,
                                                                         jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->height(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in height");
        return nullptr;
    }
}

/**
 * Checks transit availability.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeTransitAvailable
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeTransitAvailable(
    JNIEnv* env, jobject /* obj */, jlong handle, jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->transit_available(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in transit_available");
        return nullptr;
    }
}

/**
 * Provides expansion information.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeExpansion
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeExpansion(JNIEnv* env,
                                                                            jobject /* obj */,
                                                                            jlong handle,
                                                                            jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->expansion(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in expansion");
        return nullptr;
    }
}

/**
 * Calculates centroid.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeCentroid
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeCentroid(JNIEnv* env,
                                                                           jobject /* obj */,
                                                                           jlong handle,
                                                                           jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->centroid(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in centroid");
        return nullptr;
    }
}

/**
 * Provides status information.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeStatus
 * Signature: (JLjava/lang/String;)Ljava/lang/String;
 */
JNIEXPORT jstring JNICALL Java_global_tada_valhalla_Actor_nativeStatus(JNIEnv* env,
                                                                         jobject /* obj */,
                                                                         jlong handle,
                                                                         jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->status(request);

        return string_to_jstring(env, result);
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in status");
        return nullptr;
    }
}

/**
 * Provides tile data.
 *
 * Class:     global_tada_valhalla_Actor
 * Method:    nativeTile
 * Signature: (JLjava/lang/String;)[B
 */
JNIEXPORT jbyteArray JNICALL Java_global_tada_valhalla_Actor_nativeTile(JNIEnv* env,
                                                                          jobject /* obj */,
                                                                          jlong handle,
                                                                          jstring request_str) {
    try {
        vt::actor_t* actor = handle_to_actor(handle);
        if (actor == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException", "Invalid actor handle");
            return nullptr;
        }

        std::string request = jstring_to_string(env, request_str);
        std::string result = actor->tile(request);

        // Convert std::string to byte array
        jbyteArray byteArray = env->NewByteArray(result.size());
        if (byteArray == nullptr) {
            throwJavaException(env, "global/tada/valhalla/ValhallaException",
                             "Failed to allocate byte array");
            return nullptr;
        }

        env->SetByteArrayRegion(byteArray, 0, result.size(),
                               reinterpret_cast<const jbyte*>(result.data()));

        return byteArray;
    } catch (const std::exception& e) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException", e.what());
        return nullptr;
    } catch (...) {
        throwJavaException(env, "global/tada/valhalla/ValhallaException",
                          "Unknown error in tile");
        return nullptr;
    }
}

} // extern "C"
