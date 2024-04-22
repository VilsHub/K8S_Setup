#!/bin/bash
packageName=$1
output_packages="/get_deps/packages/$packageName"
output_others="/get_deps/others"
downloaded_list="$output_others/${packageName}_dependencies.txt"


if [ ! -f $downloaded_list ]; then
    touch $downloaded_list
fi


level=$2
: ${level:=-1} #Can either be -1 or possitve integer, and not 0
dept=1

if [[ $level -ne -1 && ! $level -gt 0 ]]; then
    level=1
fi

if [ ! -d $output_packages ]; then
    mkdir -p $output_packages
fi

if [ ! -d $output_others ]; then
    mkdir -p $output_others
fi

if [ $level -eq -1 ]; then
    label="all"
else
    label=$level
fi

echo -e "Dependency download level for this session is set to $label\n"

function getDependecies(){
    # Get the package dependencies
    readarray -t dependencies < <(repoquery --requires --resolve -q -a $1)

    for dependency in ${dependencies[@]}; do
        # Filter existing dependencies
        echo "Checking downloaded dependencies database for the package '$dependency' existence....."

        element_found=0

        readarray -t downloadedDependencies < $downloaded_list

        for item in "${downloadedDependencies[@]}"; do
            if [ "$item" = "$dependency" ]; then
                element_found=1
                break
            fi
        done

        # Write download and write to dependencies database
        if [ $element_found -eq 0 ]; then

            packageName=${dependency%%:*}
            packageName=${packageName%-*}

            # Check is package exist
            echo "Getting dependencies for the package: $packageName"
            rpm -q $packageName
            ec=$?

            if [ $ec -eq 0 ]; then 
                yumdownloader --assumeyes  --destdir=$output_packages --resolve $packageName
                
                # Add to database
                echo $dependency >> $downloaded_list

                # Check if it has sub dependencies
                readarray -t dependencies2 < <(repoquery --requires --resolve -q -a $packageName)
            
                # count the total number of dependencies
                total_deps=${#dependencies2[@]}

                if [ $total_deps -gt 0 ]; then

                    if [ $level -eq -1 ]; then

                        # Download all depencies
                        getDependecies $packageName

                    elif [ $dept < $level ]; then

                        # Continue finding dependency
                        (($dept += 1))
                        getDependecies $packageName

                    fi
                    
                fi

            elif [ $ec -ne 0 ]; then
                # Add to list of packages to be downloaded
                echo $packageName >> $output_others"/list.txt"
            fi
        else

            echo -e "The package '$packageName' has been downloaded already.... skipped\n"
            
        fi

    done  
}


getDependecies $packageName