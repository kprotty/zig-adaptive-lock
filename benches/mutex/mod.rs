// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use std::{
    thread,
    env
};

fn bench_all(b: &mut Benchmarker) {

}

pub fn main() {

}

struct Parser;

impl Parser {
    fn parse<T>(
        input: Option<String>,
        resolve: impl FnMut(&mut Vec<T>, (u64, Option<u64>), Option<(u64, Option<u64>)>),
    ) -> Vec<T> {
        let mut results = Vec::new();
        let input = input.unwrap_or_else(|| Self::error("invalid argument"));
        let mut input = input.chars().peekable(); 

        let mut parse_value = || {
            let mut value = None;
            while let Some(&c) = input.peek() {
                if c > '0
            }
        };

        loop {
            let first = Self::parse_value(&mut )
        }

        results
    }

    fn error(message: &'static str) -> ! {
        eprintln!("Error: {:?}\n", message);
        Self::print_help(std::env::args().next().unwrap());
        std::process::exit(1)
    }

    fn print_help(exe: String) {
        println!("Usage: {} [measure] [threads] [locked] [unlocked]", exe);
        println!("where:");

        println!();
        println!(" [measure]: [csv-ranged:time]\t\\\\ List of time spent measuring for each mutex benchmark");
        println!(" [threads]: [csv-ranged:count]\t\\\\ List of thread counts for each benchmark");
        println!(" [locked]: [csv-ranged:time]\t\\\\ List of time spent inside the lock for each benchmark");
        println!(" [unlocked]: [csv-ranged:time]\t\\\\ List of time spent outside the lock for each benchmark");

        println!();
        println!(" [count]: {{usize}}");
        println!(" [time]: {{u128}}[time_unit]");
        println!(" [time_unit]: \"ns\" | \"us\" | \"ms\" | \"s\"");

        println!();
        println!(" [csv_ranged:{{rule}}]: {{rule}}");
        println!("   | {{rule}} \"-\" {{rule}} \t\t\t\t\t\\\\ randomized value in range");
        println!(
            "   | [csv_ranged:{{rule}}] \",\" [csv_ranged:{{rule}}] \t\\\\ multiple permutations"
        );
        println!();
    }
}