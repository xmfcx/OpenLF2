find_package(Git QUIET)
set(openlf2_git_hash "unknown")
if(GIT_FOUND)
    execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --short=7 HEAD
        WORKING_DIRECTORY "${OPENLF2_SOURCE_DIR}"
        OUTPUT_VARIABLE openlf2_git_output
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE openlf2_git_result
        ERROR_QUIET)
    if(openlf2_git_result EQUAL 0)
        set(openlf2_git_hash "${openlf2_git_output}")
    endif()
endif()
# The game version (OpenLF2 extension): the commit's day in UTC and its place among that day's commits, for example
# 2026.10.25-2, with "+dirty" when tracked files differ from the commit.
set(openlf2_version_id "${OPENLF2_VERSION}")
if(GIT_FOUND AND openlf2_git_result EQUAL 0)
    execute_process(COMMAND "${CMAKE_COMMAND}" -E env TZ=UTC0
            "${GIT_EXECUTABLE}" log --date=format-local:%Y.%m.%d --format=%cd HEAD
        WORKING_DIRECTORY "${OPENLF2_SOURCE_DIR}"
        OUTPUT_VARIABLE openlf2_commit_days
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE openlf2_days_result
        ERROR_QUIET)
    if(openlf2_days_result EQUAL 0 AND openlf2_commit_days)
        string(REPLACE "\n" ";" openlf2_commit_days "${openlf2_commit_days}")
        list(GET openlf2_commit_days 0 openlf2_commit_day)
        set(openlf2_same_day 0)
        foreach(openlf2_day IN LISTS openlf2_commit_days)
            if(openlf2_day STREQUAL openlf2_commit_day)
                math(EXPR openlf2_same_day "${openlf2_same_day} + 1")
            endif()
        endforeach()
        set(openlf2_version_id "${openlf2_commit_day}-${openlf2_same_day}")
    endif()
    execute_process(COMMAND "${GIT_EXECUTABLE}" status --porcelain --untracked-files=no
        WORKING_DIRECTORY "${OPENLF2_SOURCE_DIR}"
        OUTPUT_VARIABLE openlf2_changes
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
    if(openlf2_changes)
        string(APPEND openlf2_version_id "+dirty")
    endif()
endif()
file(CONFIGURE OUTPUT "${OPENLF2_BUILD_INFO}" CONTENT
    "#pragma once\n#define OPENLF2_BUILD_LABEL \"OpenLF2 ${openlf2_version_id} (${openlf2_git_hash})\"\n#define OPENLF2_VERSION_ID \"${openlf2_version_id}\"\n#define OPENLF2_COMMIT \"${openlf2_git_hash}\"\n")
